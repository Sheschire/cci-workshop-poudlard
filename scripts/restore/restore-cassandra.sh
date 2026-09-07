#!/usr/bin/env bash
# =============================================================================
# restore-cassandra — restore the `datalake` keyspace (CDC §9.2).
#
#   scripts/restore/restore-cassandra.sh <node> [options] [snapshot-id]
#
#   <node>            1, 2 or 3 — which node's snapshot to restore FROM
#   --keyspace NAME   restore into another keyspace (the drill uses
#                     datalake_restore, so production is never touched)
#   --yes             do not ask for confirmation
#
# Method: sstableloader, not a file copy
# --------------------------------------
# The obvious restore — drop the SSTables back into data/<ks>/<table>/ and run
# `nodetool refresh` — only works if the ring has the SAME topology and the
# SAME token ranges as when the snapshot was taken. After a node replacement,
# it silently loads data the node does not own, and the rows become invisible.
#
# `sstableloader` streams the SSTables through the normal write path instead:
# every row is routed to whichever nodes own it TODAY, at RF=3. It is slower,
# and it is the only method that is correct whatever happened to the ring.
# The "same topology" shortcut is documented in docs/07-PRA.md for the case it
# genuinely applies to — a single node coming back with its tokens intact.
# =============================================================================
set -Eeuo pipefail
# Paths are relative to --source-path=scripts (see the lint-shell target).
# shellcheck source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=restore/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

need_manager
load_env
cd "$DW_ROOT"

NODE=""
KEYSPACE="datalake"
SNAPSHOT="latest"
while (( $# )); do
  case "$1" in
    --keyspace) KEYSPACE="${2:?--keyspace needs a name}"; shift 2 ;;
    --yes)      ASSUME_YES=1; shift ;;
    -h|--help)  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         die "unknown option: $1" ;;
    [123])      NODE="$1"; shift ;;
    *)          SNAPSHOT="$1"; shift ;;
  esac
done

[[ -n "$NODE" ]] || die "usage: restore-cassandra.sh <1|2|3> [--keyspace NAME] [snapshot-id]"
SNAPSHOT="$(pick_snapshot "cassandra-${NODE}" "$SNAPSHOT")"

RESTORE_SECRETS+=(dw_cassandra_admin_password dw_cassandra_backup_password)

confirm "About to restore the Cassandra snapshot of node ${NODE} (${SNAPSHOT}) into keyspace '${KEYSPACE}'.
Rows present in the snapshot will be written back at RF=3. Existing rows with a
NEWER write timestamp win — Cassandra resolves the conflict by timestamp, so a
restore never silently reverts more recent data."

# --- 1. Restore the SSTables into a scratch volume ----------------------------
# A named volume rather than a bind mount: sstableloader reads thousands of
# small files and an overlay-fs scratch directory on the host would be slower
# and would not survive a container restart mid-load.
readonly SCRATCH_VOLUME="dw_restore_cassandra_${NODE}"
docker volume create "$SCRATCH_VOLUME" >/dev/null

cleanup() {
  local rc=$?
  docker volume rm "$SCRATCH_VOLUME" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT

section "Restoring the SSTables (snapshot ${SNAPSHOT})"
RESTORE_MOUNTS=(-v "${SCRATCH_VOLUME}:/restore")
restic_run_writable restic restore "$SNAPSHOT" --tag "cassandra-${NODE}" --target /restore \
  || die "restic restore failed"
ok "SSTables restored"

# --- 2. Recreate the keyspace and the tables ----------------------------------
# The keyspace definition captured by the backup job carries the replication
# strategy and factor. Loading tables into a keyspace created with RF=1 would
# produce a cluster that looks fine and loses data on the first node failure.
section "Schema"
# Expanded inside the container, where /run/secrets exists.
# shellcheck disable=SC2016
schema_script='
  set -eu
  ks="$1"; target_ks="$2"
  cred=/tmp/.cqlshrc
  printf "[PlainTextAuthProvider]\nusername = backup\npassword = %s\n" \
    "$(cat /run/secrets/dw_cassandra_backup_password)" > "$cred"
  chmod 600 "$cred"
  schema="$(find /restore -name "${ks}.cql" -type f | head -1)"
  if [ -z "$schema" ]; then
    echo "no ${ks}.cql in the snapshot; falling back on the per-table schema.cql" >&2
    schema=""
  fi
  if [ -n "$schema" ]; then
    # Rewrite the keyspace name so the drill can load into datalake_restore.
    sed "s/\\b${ks}\\b/${target_ks}/g" "$schema" > /tmp/schema.cql
    CQLSH_HOST=cassandra-1 cqlsh --credentials="$cred" -f /tmp/schema.cql
  else
    for f in $(find /restore -name schema.cql -type f); do
      sed "s/\\b${ks}\\b/${target_ks}/g" "$f" > /tmp/one.cql
      CQLSH_HOST=cassandra-1 cqlsh --credentials="$cred" -f /tmp/one.cql || true
    done
  fi
'
restic_run_writable bash -c "$schema_script" _ datalake "$KEYSPACE" \
  || die "the schema could not be created — check config/cassandra/init.cql"
ok "keyspace ${KEYSPACE} and its tables exist"

# --- 3. sstableloader ---------------------------------------------------------
# The restored tree is .../<table>/snapshots/daily/*.db. sstableloader expects a
# directory whose last two components are <keyspace>/<table>, so each table's
# snapshot is presented under that shape before being streamed.
section "Streaming with sstableloader"
# Expanded inside the container, where /run/secrets exists.
# shellcheck disable=SC2016
load_script='
  set -Eeuo pipefail
  target_ks="$1"
  cass_pw="$(cat /run/secrets/dw_cassandra_backup_password)"
  loaded=0
  for snap in $(find /restore -type d -path "*/snapshots/daily"); do
    table_dir="$(dirname "$(dirname "$snap")")"
    table="$(basename "$table_dir" | sed "s/-[0-9a-f]\{32\}$//")"
    staging="/tmp/load/${target_ks}/${table}"
    mkdir -p "$staging"
    cp "$snap"/*.db "$staging"/ 2>/dev/null || continue
    echo "  ${table}: $(ls -1 "$staging" | wc -l) file(s)" >&2
    # sstableloader has no credentials-file option, unlike nodetool and cqlsh:
    # -pw is the only form it accepts. The password is therefore visible in
    # `ps` for the lifetime of this container — a throw-away container the
    # operator started, holding credentials it already read from /run/secrets.
    sstableloader -d cassandra-1,cassandra-2,cassandra-3 \
      -u backup -pw "$cass_pw" "$staging"
    loaded=$((loaded + 1))
    rm -rf "$staging"
  done
  [ "$loaded" -gt 0 ] || { echo "no table loaded" >&2; exit 1; }
  echo "${loaded} table(s) streamed" >&2
'
# sstableloader lives in the Cassandra image, not in backup-runner: it needs
# the full server jars, which the image deliberately does not ship (nodetool
# and cqlsh only). The image is therefore swapped for this one step, keeping
# the same secret staging, capability set and network wiring — the exact
# Cassandra image the cluster runs, so the SSTable format matches by
# construction.
cass_cid="$(docker ps -q --filter 'label=com.docker.swarm.service.name=data_cassandra-1' | head -1)"
[[ -n "$cass_cid" ]] \
  || die "no data_cassandra-1 task on $(hostname) — run this from the node labelled cassandra=1"

RUNNER_IMAGE="$(docker inspect --format '{{.Config.Image}}' "$cass_cid")"
RUNNER_ENTRYPOINT=/bin/bash
info "streaming with sstableloader from ${RUNNER_IMAGE}"
runner_restore -c "$load_script" _ "$KEYSPACE" \
  || die "sstableloader failed — see docs/07-PRA.md, 'Cassandra sans quorum'"
RUNNER_IMAGE=""
RUNNER_ENTRYPOINT=""
ok "data streamed into ${KEYSPACE}"

# --- 4. Verify ----------------------------------------------------------------
section "Verification"
rows="$(docker exec "$cass_cid" sh -c \
  "cqlsh -u backup -p \"\$(cat /run/secrets/dw_cassandra_backup_password)\" \
     -e 'SELECT COUNT(*) FROM ${KEYSPACE}.events LIMIT 1;' 2>/dev/null" \
  | awk 'NR==4 {print $1}' || echo "")"
if [[ -n "$rows" ]]; then
  ok "${KEYSPACE}.events: ${rows} row(s) readable at the default consistency"
else
  warn "could not count the rows — check by hand with cqlsh"
fi

section "Restore complete"
ok "snapshot ${SNAPSHOT} of node ${NODE} restored into ${KEYSPACE}"

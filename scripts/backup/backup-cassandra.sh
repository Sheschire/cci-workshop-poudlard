#!/usr/bin/env bash
# =============================================================================
# backup-cassandra — snapshot of the `datalake` keyspace (CDC §9.1, 03:00 UTC).
#
#   backup-cassandra.sh <node-number>       1, 2 or 3
#
# One job per Cassandra member, each pinned to the member's own node and
# mounting that member's volume read-only. Cassandra has no cluster-wide
# snapshot: `nodetool snapshot` freezes the SSTables of ONE node. Backing up
# all three separately is what makes a restore possible whatever happens —
# including the loss of two nodes, where RF=3 means the survivor still holds a
# full copy.
#
# How a Cassandra snapshot works, and why this is safe:
#   1. `nodetool snapshot` flushes the memtables and creates HARD LINKS to the
#      current SSTables under snapshots/<tag>/. It costs no disk space and no
#      copy — the links simply stop the compactor from deleting those files.
#   2. restic then reads those immutable files at its leisure. SSTables are
#      never modified in place, so there is no torn read to worry about.
#   3. `nodetool clearsnapshot` drops the links. Skipping this is the classic
#      way to fill a Cassandra disk: the links keep obsolete SSTables alive
#      after compaction, and the node dies of a full volume weeks later.
# Step 3 therefore runs from a trap, whatever happens in between.
# =============================================================================
set -Eeuo pipefail
# The library lives at /opt/backup/lib.sh inside the container; the directive
# below points the linter at its source in the repository.
# shellcheck source=scripts/backup/lib.sh
source /opt/backup/lib.sh

readonly NODE_NUM="${1:?usage: backup-cassandra.sh <node-number>}"
readonly HOST="cassandra-${NODE_NUM}"
readonly KEYSPACE="${KEYSPACE:-datalake}"
readonly TAG="daily"
readonly DATA_DIR="${DATA_DIR:-/cassandra}"

job_start "backup-cassandra-${NODE_NUM}"
restic_env
ensure_repo

wait_for "$HOST" 7199 180 || die "${HOST} JMX is not reachable — is LOCAL_JMX=no set on the Cassandra service?"

# JMX credentials. `controlRole` is the read-write JMX role; snapshotting is a
# write operation on the storage service MBean, so monitorRole is not enough.
JMX_PASSWORD="$(read_secret dw_cassandra_admin_password)"

# `nodetool -pw <password>` would put the password in `ps`. `--password-file`
# does not: nodetool reads the password for the user given by `-u` from the
# file, whose format is the same whitespace-separated `<role> <password>` as
# JMX's own jmxremote.password. Written to a private tmpfs path with umask 077
# and removed by the same trap that clears the snapshot.
readonly CRED_FILE="/tmp/.nodetool-cred"
umask 077
printf '%s %s\n' controlRole "$JMX_PASSWORD" > "$CRED_FILE"

nt() {
  nodetool -h "$HOST" -p 7199 -u controlRole --password-file "$CRED_FILE" "$@"
}

cleanup() {
  local rc=$?
  # Order matters: clear the snapshot FIRST (it is what fills the disk), then
  # the credentials file.
  nt clearsnapshot -t "$TAG" "$KEYSPACE" >/dev/null 2>&1 \
    || warn "clearsnapshot failed — check for a leftover snapshots/${TAG} on ${HOST}"
  rm -f "$CRED_FILE" /tmp/.cqlshrc-cred
  job_end "$rc"
}
trap cleanup EXIT

# --- 1. Take the snapshot ----------------------------------------------------
# A snapshot from a previous, interrupted run would make `snapshot` fail with
# "snapshot daily already exists". Clearing first makes the job idempotent.
nt clearsnapshot -t "$TAG" "$KEYSPACE" >/dev/null 2>&1 || true

info "nodetool snapshot -t ${TAG} ${KEYSPACE} on ${HOST}"
nt snapshot -t "$TAG" "$KEYSPACE" >/dev/null

# --- 2. Capture the schema ---------------------------------------------------
# `nodetool snapshot` already writes a schema.cql next to each table's SSTables,
# which is what `sstableloader` and a table-level restore need. The keyspace
# DEFINITION (replication factor, strategy) is not in there, so it is captured
# separately: restoring tables into a keyspace that does not exist, or that
# exists with RF=1, is a silent data-durability regression.
readonly SCHEMA_DIR="/tmp/schema"
mkdir -p "$SCHEMA_DIR"
CQL_PASSWORD="$(read_secret dw_cassandra_backup_password)"
# Same reasoning as nodetool: `cqlsh -p <password>` is visible in `ps`, and
# cqlsh accepts a credentials file instead. Removed by the cleanup trap below.
readonly CQL_CRED_FILE="/tmp/.cqlshrc-cred"
printf '[PlainTextAuthProvider]\nusername = backup\npassword = %s\n' \
  "$CQL_PASSWORD" > "$CQL_CRED_FILE"
export CQLSH_HOST="$HOST" CQLSH_PORT=9042
if cqlsh --credentials="$CQL_CRED_FILE" -e "DESCRIBE KEYSPACE ${KEYSPACE};" \
     > "${SCHEMA_DIR}/${KEYSPACE}.cql" 2>/dev/null \
   && [[ -s "${SCHEMA_DIR}/${KEYSPACE}.cql" ]]; then
  ok "keyspace schema captured ($(wc -l < "${SCHEMA_DIR}/${KEYSPACE}.cql") lines)"
else
  # Not fatal: every table's schema.cql is inside the snapshot, and
  # config/cassandra/init.cql in git recreates the keyspace. Loud, though —
  # a restore is measurably harder without this file.
  warn "cqlsh DESCRIBE KEYSPACE failed; falling back on the per-table schema.cql"
  warn "  inside the snapshot and on config/cassandra/init.cql in git"
  printf -- '-- cqlsh unavailable at backup time; see config/cassandra/init.cql\n' \
    > "${SCHEMA_DIR}/${KEYSPACE}.cql"
fi

# --- 3. Archive --------------------------------------------------------------
# Only the snapshot directories, never the live data: `--tag` scopes the
# restore, and restic deduplicates the SSTables across days, so a snapshot that
# has not changed since yesterday costs nothing.
readonly KS_DIR="${DATA_DIR}/data/${KEYSPACE}"
[[ -d "$KS_DIR" ]] || die "${KS_DIR} not found — is cassandra_data_${NODE_NUM} mounted?"

mapfile -t snapshot_dirs < <(find "$KS_DIR" -type d -path "*/snapshots/${TAG}" 2>/dev/null | sort)
(( ${#snapshot_dirs[@]} > 0 )) \
  || die "no snapshots/${TAG} directory under ${KS_DIR} — the snapshot did not land on this node"

info "archiving ${#snapshot_dirs[@]} table snapshot(s)"
restic backup "${snapshot_dirs[@]}" "$SCHEMA_DIR" \
  --tag "cassandra-${NODE_NUM}" \
  --tag cassandra \
  --host dockerwarts \
  --quiet

job_size "$(restic_snapshot_size "cassandra-${NODE_NUM}")"
ok "node ${NODE_NUM} archived"

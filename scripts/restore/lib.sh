#!/usr/bin/env bash
# =============================================================================
# Shared helpers for scripts/restore/* (CDC §9.2).
#
# Sourced (never executed) by every restore script. Unlike scripts/backup/lib.sh
# — which runs INSIDE the backup-runner container — this one runs on a Swarm
# MANAGER, driven by an operator during an incident.
#
# The central problem it solves
# -----------------------------
# A restore needs the same credentials the backup jobs have, but there is no
# running backup container to `docker exec` into: the jobs are `replicas: 0`
# services that exist only while they run. And `docker run -e PASSWORD=…` would
# put every credential in `docker inspect` and in `ps` on the host.
#
# So `runner` starts a one-shot backup-runner container with the local secret
# files (secrets/, the ones `make secrets` produced from the vault) staged into
# a private directory and bind-mounted at /run/secrets — the exact layout the
# job scripts already expect. The staging directory is 0700, lives for the
# duration of the command, and is removed by a trap even on Ctrl-C.
#
# This is also why docs/07-PRA.md insists that `make secrets` (from the vault)
# comes BEFORE any restore in the rebuild procedure: without secrets/, nothing
# here can decrypt anything.
# =============================================================================

[[ -n "${DW_RESTORE_LIB:-}" ]] && return 0
readonly DW_RESTORE_LIB=1

# --- Configuration a caller may override -------------------------------------
RESTORE_NETWORKS=(data)
RESTORE_MOUNTS=()
RESTORE_SECRETS=(dw_restic_password dw_minio_restic_key dw_minio_restic_secret)
RESTORE_ENV=()

# The image a one-shot container runs. Almost always backup-runner; the
# Cassandra restore overrides it, because `sstableloader` needs the full server
# jars — which backup-runner deliberately does not ship (it carries nodetool and
# cqlsh only). Overriding the image keeps the secret staging, the capability set
# and the network wiring identical whichever tool is being run.
RUNNER_IMAGE=""
# Images that declare their own ENTRYPOINT (the Cassandra one does) need it
# bypassed, or the command below is passed to it as arguments instead of being
# run. backup-runner declares only a CMD, so this stays empty for it.
RUNNER_ENTRYPOINT=""
runner_image() {
  if [[ -n "$RUNNER_IMAGE" ]]; then
    printf '%s' "$RUNNER_IMAGE"
    return 0
  fi
  printf '%s/dockerwarts/backup-runner:%s' "${REGISTRY}" "${IMAGE_TAG}"
}

# -----------------------------------------------------------------------------
# _stage_secrets — copy the requested secrets into a private directory, under
# the names the scripts expect (`dw_x`, not `dw_x.txt`).
# -----------------------------------------------------------------------------
DW_STAGE=""
_stage_secrets() {
  DW_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dw-restore.XXXXXX")"
  chmod 700 "$DW_STAGE"
  local name src
  for name in "${RESTORE_SECRETS[@]}"; do
    src="${DW_SECRETS_DIR}/${name}.txt"
    [[ -r "$src" ]] || die "missing secret ${src} — run 'make secrets' from the vault first (docs/07-PRA.md)"
    install -m 0400 "$src" "${DW_STAGE}/${name}"
  done
}

_unstage_secrets() {
  [[ -n "$DW_STAGE" ]] && rm -rf "$DW_STAGE"
  DW_STAGE=""
}
# Removed even if the operator interrupts a long restore.
trap '_unstage_secrets' EXIT INT TERM

# -----------------------------------------------------------------------------
# runner <command…> — a one-shot backup-runner container, READ-ONLY operations.
#
# Runs as root so that it can read the staged secrets (0400, owned by the
# operator) — with every capability dropped, so "root" here means "can read the
# files we handed it" and nothing more.
# -----------------------------------------------------------------------------
runner() {
  _stage_secrets
  local -a args=(
    --rm -i
    --user 0:0
    --cap-drop ALL
    --security-opt no-new-privileges:true
    --tmpfs /tmp:size=256M
    -v "${DW_STAGE}:/run/secrets:ro"
    -e "RESTIC_REPOSITORY=${RESTIC_REPOSITORY:-s3:http://minio:9000/restic}"
    -e "RESTIC_CACHE_DIR=/tmp/restic-cache"
  )
  [[ -n "$RUNNER_ENTRYPOINT" ]] && args+=(--entrypoint "$RUNNER_ENTRYPOINT")
  local net
  for net in "${RESTORE_NETWORKS[@]}"; do args+=(--network "$net"); done
  local extra
  for extra in "${RESTORE_ENV[@]}"; do args+=(-e "$extra"); done
  args+=("${RESTORE_MOUNTS[@]}")

  local rc=0
  docker run "${args[@]}" "$(runner_image)" "$@" || rc=$?
  _unstage_secrets
  return "$rc"
}

# -----------------------------------------------------------------------------
# runner_restore <command…> — same, for operations that WRITE files.
#
# `restic restore` re-applies the ownership recorded in the archive, which is
# the whole point: GLPI's files must come back owned by uid 1000, Prometheus's
# TSDB by 65534. Changing a file's owner needs CAP_CHOWN, and writing into a
# directory owned by someone else needs DAC_OVERRIDE, so exactly those three
# capabilities are added back — never the whole set.
# -----------------------------------------------------------------------------
runner_restore() {
  _stage_secrets
  local -a args=(
    --rm -i
    --user 0:0
    --cap-drop ALL
    --cap-add CHOWN
    --cap-add DAC_OVERRIDE
    --cap-add FOWNER
    --security-opt no-new-privileges:true
    --tmpfs /tmp:size=256M
    -v "${DW_STAGE}:/run/secrets:ro"
    -e "RESTIC_REPOSITORY=${RESTIC_REPOSITORY:-s3:http://minio:9000/restic}"
    -e "RESTIC_CACHE_DIR=/tmp/restic-cache"
  )
  [[ -n "$RUNNER_ENTRYPOINT" ]] && args+=(--entrypoint "$RUNNER_ENTRYPOINT")
  local net
  for net in "${RESTORE_NETWORKS[@]}"; do args+=(--network "$net"); done
  local extra
  for extra in "${RESTORE_ENV[@]}"; do args+=(-e "$extra"); done
  args+=("${RESTORE_MOUNTS[@]}")

  local rc=0
  docker run "${args[@]}" "$(runner_image)" "$@" || rc=$?
  _unstage_secrets
  return "$rc"
}

# -----------------------------------------------------------------------------
# restic_run <restic args…> — restic with the credentials wired up.
#
# The password and the S3 keys are read from /run/secrets INSIDE the container
# by a one-line shell, so they never appear in the docker command line.
# -----------------------------------------------------------------------------
# The variables below must expand INSIDE the container, from /run/secrets —
# not here, where those files do not exist. Single quotes are the point.
# shellcheck disable=SC2016
readonly RESTIC_WRAPPER='
  set -eu
  RESTIC_PASSWORD="$(cat /run/secrets/dw_restic_password)"
  AWS_ACCESS_KEY_ID="$(cat /run/secrets/dw_minio_restic_key)"
  AWS_SECRET_ACCESS_KEY="$(cat /run/secrets/dw_minio_restic_secret)"
  export RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  exec restic "$@"
'

restic_run()          { runner         bash -c "$RESTIC_WRAPPER" _ "$@"; }
restic_run_writable() { runner_restore bash -c "$RESTIC_WRAPPER" _ "$@"; }

# -----------------------------------------------------------------------------
# pick_snapshot TAG [ID] — resolve the snapshot to restore.
#
# With no ID, `latest` is used. With one, it is CHECKED to exist and to carry
# the expected tag: restoring the Cassandra snapshot of node 2 into node 1 by
# fat-fingering an id is a mistake that only shows up much later.
# -----------------------------------------------------------------------------
pick_snapshot() {
  local tag=$1 id="${2:-latest}"
  if [[ "$id" == "latest" ]]; then
    printf 'latest'
    return 0
  fi
  if restic_run snapshots --tag "$tag" --json 2>/dev/null \
       | grep -q "\"$(cut -c1-8 <<<"$id")"; then
    printf '%s' "$id"
    return 0
  fi
  die "snapshot ${id} not found with tag '${tag}' — list them with: scripts/restore/restore-all.sh --list"
}

# -----------------------------------------------------------------------------
# confirm MESSAGE — a destructive step asks, unless --yes was passed.
#
# Every restore script accepts --yes for the drill and for the rebuild
# procedure, which run unattended. Interactively, the default is NO: a restore
# overwrites live data, and a mistyped command at 3 a.m. is exactly the risk.
# -----------------------------------------------------------------------------
ASSUME_YES=0
confirm() {
  (( ASSUME_YES )) && return 0
  local answer
  printf '\n%s\n' "$*" >&2
  read -r -p "Type 'yes' to continue: " answer
  [[ "$answer" == "yes" ]] || die "aborted by the operator"
}

# -----------------------------------------------------------------------------
# scale_service NAME REPLICAS — stop or restart a service around a restore.
#
# Restoring files under a running application is how a restore produces a
# half-old, half-new state that nobody can reason about. The scripts that touch
# live data stop the consumers first and bring them back afterwards, from a
# trap, so an interrupted restore does not leave the platform down.
# -----------------------------------------------------------------------------
scale_service() {
  local svc=$1 replicas=$2
  docker service inspect "$svc" >/dev/null 2>&1 || { warn "${svc}: absent, nothing to scale"; return 0; }
  docker service update --detach=true --replicas "$replicas" "$svc" >/dev/null
  info "${svc} → ${replicas} replica(s)"
}

#!/usr/bin/env bash
# =============================================================================
# Shared library for every backup job (CDC §7.7, §9.1).
#
# Sourced by each scripts/backup/*.sh, which run INSIDE the backup-runner
# container. This file is therefore deliberately independent from
# scripts/lib/common.sh (which assumes a Docker CLI and a Swarm manager).
#
# What it provides, and why each piece exists:
#
#   job_start / job_end     bracket a job and PUBLISH ITS METRIC — this is what
#                           turns "we have backups" into "we know they ran"
#   restic_env              wire restic to MinIO from the mounted secrets
#   ensure_repo             initialise the repository on first use
#   metric_write            atomic write of the Prometheus textfile
#
# The metric is the whole point. A backup job that silently stops is worse
# than no backup at all, because it produces false confidence. Every job here
# publishes four series, and BackupTooOld / BackupFailed watch them.
# =============================================================================

[[ -n "${DW_BACKUP_LIB:-}" ]] && return 0
readonly DW_BACKUP_LIB=1

set -Eeuo pipefail

# --- Where the metrics go ----------------------------------------------------
# A directory on the shared NFS export, written by the jobs (wherever they are
# scheduled) and served by the `backup-metrics` nginx. NFS is used here — and
# only here — because the writer and the reader are on different nodes.
readonly METRICS_DIR="${METRICS_DIR:-/metrics}"
readonly METRICS_FILE="${METRICS_DIR}/backup.prom"

# --- Logging -----------------------------------------------------------------
_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log()   { printf '[%s] %s\n' "$(_ts)" "$*" >&2; }
info()  { printf '[%s] ▸ %s\n' "$(_ts)" "$*" >&2; }
ok()    { printf '[%s] ✔ %s\n' "$(_ts)" "$*" >&2; }
warn()  { printf '[%s] ⚠ %s\n' "$(_ts)" "$*" >&2; }
error() { printf '[%s] ✘ %s\n' "$(_ts)" "$*" >&2; }
die()   { error "$*"; exit 1; }

# -----------------------------------------------------------------------------
# read_secret NAME
#
# Reads /run/secrets/NAME. An absent or EMPTY secret is fatal: a mounted but
# empty file means the generation step failed, and a backup encrypted with an
# empty password is a backup nobody can restore — the failure would only be
# discovered on the day it matters.
# -----------------------------------------------------------------------------
read_secret() {
  local name=$1 path="/run/secrets/$1" value
  [[ -r "$path" ]] || die "secret ${name} is not readable (not mounted?)"
  value="$(< "$path")"
  [[ -n "$value" ]] || die "secret ${name} is empty — refusing to run"
  printf '%s' "$value"
}

# -----------------------------------------------------------------------------
# restic_env — export everything restic needs.
#
# Credentials go through the ENVIRONMENT and not the command line: anything on
# a command line is visible in `ps` to every process in the container.
# -----------------------------------------------------------------------------
restic_env() {
  RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-s3:http://minio:9000/restic}"
  RESTIC_PASSWORD="$(read_secret dw_restic_password)"
  AWS_ACCESS_KEY_ID="$(read_secret dw_minio_restic_key)"
  AWS_SECRET_ACCESS_KEY="$(read_secret dw_minio_restic_secret)"
  export RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  # Bound the memory restic uses to pack blobs: on a 6 GB node shared with
  # three databases, the default can push a JVM into the OOM killer.
  export GOGC=20
}

# -----------------------------------------------------------------------------
# ensure_repo — initialise the restic repository if this is the first run.
#
# `restic cat config` is the cheap, read-only way to ask "does this repository
# exist?". `restic init` on an existing repository is an error, so it cannot
# simply be run unconditionally.
# -----------------------------------------------------------------------------
ensure_repo() {
  if restic cat config >/dev/null 2>&1; then
    return 0
  fi
  info "restic repository absent — initialising"
  restic init
  ok "repository initialised at ${RESTIC_REPOSITORY}"
}

# =============================================================================
# Metrics
# =============================================================================
# metric_write JOB STATUS DURATION SIZE
#
# Rewrites the WHOLE file, preserving the lines of the other jobs, then moves
# it into place atomically. Two reasons this is not an append:
#   * a metric must not be duplicated: Prometheus would refuse the scrape with
#     "duplicate series" and EVERY backup metric would disappear at once;
#   * several jobs run at the same time on different nodes, all writing to the
#     same NFS file. `mv` is atomic on NFSv4, a partial write is not.
# -----------------------------------------------------------------------------
metric_write() {
  local job=$1 status=$2 duration=$3 size=$4
  local now tmp
  now="$(date -u +%s)"
  mkdir -p "$METRICS_DIR"
  tmp="$(mktemp "${METRICS_DIR}/.backup.prom.XXXXXX")"

  {
    printf '# HELP backup_last_success_timestamp Unix timestamp of the last successful run\n'
    printf '# TYPE backup_last_success_timestamp gauge\n'
    printf '# HELP backup_last_status Exit status of the last run (0 = success)\n'
    printf '# TYPE backup_last_status gauge\n'
    printf '# HELP backup_last_duration_seconds Duration of the last run\n'
    printf '# TYPE backup_last_duration_seconds gauge\n'
    printf '# HELP backup_last_size_bytes Size of the last backup\n'
    printf '# TYPE backup_last_size_bytes gauge\n'
  } > "$tmp"

  # Carry over every OTHER job's lines unchanged.
  if [[ -f "$METRICS_FILE" ]]; then
    grep -v "^#" "$METRICS_FILE" 2>/dev/null | grep -v "job=\"${job}\"" >> "$tmp" || true
  fi

  # On failure the SUCCESS timestamp is deliberately NOT refreshed: it must
  # keep pointing at the last run that actually worked, which is what
  # BackupTooOld measures. Only the status changes.
  if [[ "$status" == "0" ]]; then
    printf 'backup_last_success_timestamp{job="%s"} %s\n' "$job" "$now" >> "$tmp"
  elif [[ -f "$METRICS_FILE" ]]; then
    grep "^backup_last_success_timestamp{job=\"${job}\"}" "$METRICS_FILE" >> "$tmp" 2>/dev/null || true
  fi

  {
    printf 'backup_last_status{job="%s"} %s\n' "$job" "$status"
    printf 'backup_last_duration_seconds{job="%s"} %s\n' "$job" "$duration"
    printf 'backup_last_size_bytes{job="%s"} %s\n' "$job" "$size"
  } >> "$tmp"

  chmod 0644 "$tmp"
  mv -f "$tmp" "$METRICS_FILE"
}

# -----------------------------------------------------------------------------
# job_start NAME / job_end
#
# job_end runs from an EXIT trap, so the metric is published whether the job
# succeeded, failed, or was killed. A job that dies without publishing would
# look "too old" hours later instead of "failed" immediately — the operator
# would lose those hours.
# -----------------------------------------------------------------------------
DW_JOB_NAME=""
DW_JOB_START=0
DW_JOB_SIZE=0

job_start() {
  DW_JOB_NAME=$1
  DW_JOB_START="$(date -u +%s)"
  DW_JOB_SIZE=0
  info "=== ${DW_JOB_NAME} starting ==="
  trap 'job_end $?' EXIT
}

job_size() { DW_JOB_SIZE="${1:-0}"; }

job_end() {
  local status=${1:-0} duration
  trap - EXIT
  [[ -n "$DW_JOB_NAME" ]] || return 0
  duration=$(( $(date -u +%s) - DW_JOB_START ))

  if metric_write "$DW_JOB_NAME" "$status" "$duration" "$DW_JOB_SIZE"; then
    :
  else
    error "could not write the metric for ${DW_JOB_NAME} — is ${METRICS_DIR} mounted?"
  fi

  if [[ "$status" == "0" ]]; then
    ok "=== ${DW_JOB_NAME} finished in ${duration}s (${DW_JOB_SIZE} bytes) ==="
  else
    error "=== ${DW_JOB_NAME} FAILED (status ${status}) after ${duration}s ==="
  fi
  exit "$status"
}

# -----------------------------------------------------------------------------
# restic_snapshot_size TAG — bytes added by the most recent snapshot.
#
# `--mode raw-data` reports what actually landed in the repository, i.e. AFTER
# deduplication and compression. That is the number an operator needs to plan
# capacity; the logical size would be wildly optimistic.
# -----------------------------------------------------------------------------
restic_snapshot_size() {
  local tag=$1
  restic stats --mode raw-data --tag "$tag" latest --json 2>/dev/null \
    | jq -r '.total_size // 0' 2>/dev/null || printf '0'
}

# =============================================================================
# Docker API, through the read-only socket proxy
# =============================================================================
# The jobs never see /var/run/docker.sock (CDC §6.4). What they get is the
# allow-listed HTTP proxy, which exposes services, tasks, nodes and /info and
# refuses every write. curl + jq is enough: no Docker CLI in the image, so
# nothing in the container can even formulate a `docker run`.
readonly DOCKER_API="${DOCKER_API:-http://docker-socket-proxy:2375}"

docker_api() {
  curl -fsS --max-time 20 "${DOCKER_API}${1}"
}

# -----------------------------------------------------------------------------
# local_task_address SERVICE NETWORK — the overlay IP of the task of SERVICE
# running on THIS node.
#
# Needed by the jobs that back up a *local volume* of a replicated service:
# `backup-prometheus` must ask for a TSDB snapshot from the very instance whose
# volume it then reads. Resolving the service name would hit the Swarm VIP and
# land on a random replica — the snapshot would be created on another node and
# this job would archive an empty directory, successfully, for months.
# -----------------------------------------------------------------------------
local_task_address() {
  local service=$1 network=$2 node filter
  node="$(docker_api /info | jq -r '.Swarm.NodeID')"
  [[ -n "$node" && "$node" != "null" ]] || die "the Docker API did not return this node's id"

  filter="$(jq -rn --arg s "$service" \
    '{service:[$s],"desired-state":["running"]} | @uri')"

  docker_api "/tasks?filters=${filter}" \
    | jq -r --arg n "$node" --arg net "$network" '
        .[]
        | select(.NodeID == $n)
        | .NetworksAttachments[]?
        | select(.Network.Spec.Name == $net)
        | .Addresses[]?' \
    | head -1 | cut -d/ -f1
}

# -----------------------------------------------------------------------------
# wait_for HOST PORT [TIMEOUT] — a dependency may still be starting.
#
# RETURNS 1 on timeout rather than exiting: most callers want a fatal error and
# write `wait_for … || die "…"`, but the repair job wants to skip an
# unreachable node and carry on with the other two. Making the decision the
# caller's is the difference between "one node is down" and "no node was
# repaired this week".
# -----------------------------------------------------------------------------
wait_for() {
  local host=$1 port=$2 timeout=${3:-60} elapsed=0
  while (( elapsed < timeout )); do
    if (echo > "/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    elapsed=$(( elapsed + 2 ))
  done
  warn "${host}:${port} unreachable after ${timeout}s"
  return 1
}

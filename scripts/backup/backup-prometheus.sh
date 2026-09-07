#!/usr/bin/env bash
# =============================================================================
# backup-prometheus — TSDB snapshot of instance A (CDC §9.1, Sunday 04:00 UTC).
#
# Weekly and not daily, and only one of the two instances: the two Prometheus
# instances scrape the same targets and hold the same data (HA by duplication,
# ADR — CDC §7.6), so backing up both would double the volume for nothing. And
# the metrics are the least critical thing on the platform: CDC §9.4 accepts a
# 7-day RPO for them, because the configuration — which is what actually takes
# time to rebuild — lives in git.
#
# The TSDB cannot be copied file by file while Prometheus is writing to it: the
# head block is in memory and the WAL is being appended. `/api/v1/admin/tsdb/
# snapshot` is the supported way — Prometheus flushes the head and hard-links
# the blocks under snapshots/, exactly like Cassandra.
#
# The job MUST talk to the instance whose volume it reads, so it resolves the
# task running on its own node through the Docker socket proxy. Resolving the
# service name would hit the Swarm VIP and, one time in two, snapshot the
# instance on the other node — and archive an empty directory here.
# =============================================================================
set -Eeuo pipefail
# The library lives at /opt/backup/lib.sh inside the container; the directive
# below points the linter at its source in the repository.
# shellcheck source=scripts/backup/lib.sh
source /opt/backup/lib.sh

job_start backup-prometheus
restic_env
ensure_repo

readonly SERVICE="${PROM_SERVICE:-monitoring_prometheus}"
readonly NETWORK="${PROM_NETWORK:-monitoring}"
readonly DATA_DIR="${DATA_DIR:-/prometheus}"

[[ -d "$DATA_DIR" ]] || die "${DATA_DIR} is not mounted — check the volumes of stacks/backup.yml"

address="$(local_task_address "$SERVICE" "$NETWORK")"
[[ -n "$address" ]] \
  || die "no ${SERVICE} task on this node: this job must be pinned to the same node as the instance whose volume it mounts"
info "local Prometheus instance: ${address}"

# --- 1. Snapshot -------------------------------------------------------------
response="$(curl -sS --fail-with-body --max-time 300 \
              -XPOST "http://${address}:9090/api/v1/admin/tsdb/snapshot")"
name="$(jq -r '.data.name // empty' <<<"$response")"
[[ -n "$name" ]] \
  || die "the snapshot API returned no name — is --web.enable-admin-api set? Response: ${response}"

readonly SNAPSHOT_PATH="${DATA_DIR}/snapshots/${name}"
[[ -d "$SNAPSHOT_PATH" ]] \
  || die "${SNAPSHOT_PATH} does not exist: the snapshot was created on ANOTHER instance — check the placement constraint of this job"
ok "snapshot ${name} created"

# --- Cleanup -----------------------------------------------------------------
# Prometheus never deletes its own snapshots. Left behind, they pin blocks that
# retention would otherwise drop and the volume grows without bound — the same
# failure mode as a forgotten Cassandra snapshot. Removed from a trap so an
# interrupted archive does not leave one behind either. This is the one reason
# the volume is mounted read-write rather than read-only.
cleanup() {
  local rc=$?
  rm -rf "${SNAPSHOT_PATH:?}" 2>/dev/null \
    || warn "could not remove ${SNAPSHOT_PATH} — remove it by hand, it pins TSDB blocks"
  job_end "$rc"
}
trap cleanup EXIT

# --- 2. Archive --------------------------------------------------------------
info "archiving ${SNAPSHOT_PATH}"
restic backup "$SNAPSHOT_PATH" \
  --tag prometheus \
  --host dockerwarts \
  --quiet

job_size "$(restic_snapshot_size prometheus)"
ok "TSDB archived"

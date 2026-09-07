#!/usr/bin/env bash
# =============================================================================
# backup-es — trigger and VERIFY the Elasticsearch snapshot (CDC §9.1, 01:00).
#
# Elasticsearch backs itself up: the SLM policy `daily-snapshots`
# (config/elasticsearch/slm.json, installed by scripts/es-init.sh) writes a
# snapshot into the `minio` S3 repository. Copying the data directory with
# restic instead would produce an unrestorable archive — Lucene segments are
# written and merged continuously, and a file-level copy of a live node is
# torn by construction (ADR-0008).
#
# So this job does not *make* the backup. It does the two things SLM alone
# cannot do, which are what §9.1 calls `check-es-snapshot`:
#
#   1. execute the policy now, so the backup schedule is driven by the same
#      swarm-cronjob timetable as everything else and a missed run is visible;
#   2. VERIFY that the resulting snapshot reached state SUCCESS, and publish
#      the metric — otherwise a snapshot failing every night for a month would
#      be invisible until the day it is needed.
#
# `PARTIAL` counts as a failure here, deliberately: a snapshot missing shards
# is not a backup, and CDC §9.4 promises a 24 h RPO on the whole cluster.
# =============================================================================
set -Eeuo pipefail
# The library lives at /opt/backup/lib.sh inside the container; the directive
# below points the linter at its source in the repository.
# shellcheck source=scripts/backup/lib.sh
source /opt/backup/lib.sh

job_start backup-es

readonly ES_HOST="${ES_HOST:-es-1}"
readonly ES_PORT="${ES_PORT:-9200}"
readonly POLICY="${POLICY:-daily-snapshots}"
readonly REPOSITORY="${REPOSITORY:-minio}"
readonly TIMEOUT="${SNAPSHOT_TIMEOUT:-3600}"

wait_for "$ES_HOST" "$ES_PORT" 180 || die "${ES_HOST} is not reachable — is the data stack up?"

ES_PASSWORD="$(read_secret dw_es_elastic_password)"

# curl reads the credentials from a config file on stdin rather than from
# --user on the command line, for the usual `ps` reason.
es() {
  local method=$1 path=$2
  curl -sS --fail-with-body --max-time 120 \
       -H 'Content-Type: application/json' \
       --config - \
       -X "$method" "http://${ES_HOST}:${ES_PORT}${path}" <<EOF
user = "elastic:${ES_PASSWORD}"
EOF
}

# --- 1. Execute the policy ---------------------------------------------------
# The response carries the name of the snapshot it just started, which is the
# only reliable way to know which one to watch: another snapshot may be
# running, and "the latest" would be the wrong one.
info "executing the SLM policy ${POLICY}"
snapshot_name="$(es PUT "/_slm/policy/${POLICY}/_execute" | jq -r '.snapshot_name // empty')"
[[ -n "$snapshot_name" ]] \
  || die "SLM did not return a snapshot name — is the policy installed? (scripts/es-init.sh)"
info "snapshot ${snapshot_name} started"

# --- 2. Wait for it to finish ------------------------------------------------
# A snapshot is asynchronous. Polling `_snapshot/<repo>/<name>` is cheap and,
# unlike `_status`, does not load the whole shard-level detail on every call.
elapsed=0
state=""
while (( elapsed < TIMEOUT )); do
  state="$(es GET "/_snapshot/${REPOSITORY}/${snapshot_name}" \
           | jq -r '.snapshots[0].state // "MISSING"')"
  [[ "$state" == "IN_PROGRESS" || "$state" == "MISSING" ]] || break
  sleep 15
  elapsed=$(( elapsed + 15 ))
done

# --- 3. Verify ---------------------------------------------------------------
detail="$(es GET "/_snapshot/${REPOSITORY}/${snapshot_name}")"
state="$(jq -r '.snapshots[0].state // "MISSING"' <<<"$detail")"
failed="$(jq -r '.snapshots[0].shards.failed // 0' <<<"$detail")"
total="$(jq -r '.snapshots[0].shards.total // 0' <<<"$detail")"

case "$state" in
  SUCCESS)
    ok "snapshot ${snapshot_name}: SUCCESS (${total} shards, 0 failed)"
    ;;
  PARTIAL)
    die "snapshot ${snapshot_name}: PARTIAL — ${failed}/${total} shards failed. A snapshot missing shards is not a backup; check the cluster health and re-run."
    ;;
  IN_PROGRESS)
    die "snapshot ${snapshot_name} still running after ${TIMEOUT}s — check the MinIO bandwidth and the repository settings"
    ;;
  *)
    die "snapshot ${snapshot_name}: state ${state}. Details: $(jq -c '.snapshots[0].failures // []' <<<"$detail")"
    ;;
esac

# --- 4. Size -----------------------------------------------------------------
# The size reported is the size of the whole repository, not of this snapshot:
# ES snapshots are incremental at the segment level, and what an operator needs
# for capacity planning is what MinIO actually holds.
repo_bytes="$(es GET "/_snapshot/${REPOSITORY}/_status" \
              | jq -r '[.snapshots[]?.stats.total.size_in_bytes // 0] | add // 0' 2>/dev/null || echo 0)"
job_size "$repo_bytes"

# --- 5. Retention ------------------------------------------------------------
# SLM's own retention runs on its internal schedule. Triggering it here keeps
# expired snapshots from accumulating in MinIO if that scheduler ever stalls —
# and a full bucket stops every other backup, not just this one.
if es POST '/_slm/_execute_retention' >/dev/null 2>&1; then
  ok "SLM retention triggered"
else
  warn "SLM retention could not be triggered (non-fatal)"
fi

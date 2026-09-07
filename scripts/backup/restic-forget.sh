#!/usr/bin/env bash
# =============================================================================
# restic-forget — retention and integrity (CDC §9.1, 06:00 UTC).
#
#   restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
#   restic check                                          (Sundays only)
#
# Two jobs in one, because they are two halves of the same idea: a repository
# nobody prunes fills MinIO until every backup starts failing, and a repository
# nobody checks is a repository whose integrity is unknown until the day of the
# restore.
#
# Retention is applied PER TAG (`--group-by tags`). Without that, restic would
# consider all snapshots together and "the last 7 days" could easily mean seven
# Cassandra snapshots and nothing else — silently dropping the SQL dumps.
# =============================================================================
set -Eeuo pipefail
# The library lives at /opt/backup/lib.sh inside the container; the directive
# below points the linter at its source in the repository.
# shellcheck source=scripts/backup/lib.sh
source /opt/backup/lib.sh

job_start restic-forget
restic_env

# Not ensure_repo: if the repository does not exist there is nothing to prune,
# and creating one here would hide the fact that no backup has ever run.
restic cat config >/dev/null 2>&1 \
  || die "no restic repository at ${RESTIC_REPOSITORY} — no backup has ever run"

readonly KEEP_DAILY="${KEEP_DAILY:-7}"
readonly KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
readonly KEEP_MONTHLY="${KEEP_MONTHLY:-6}"

before="$(restic stats --mode raw-data latest --json 2>/dev/null | jq -r '.total_size // 0')"

# --- 1. Forget + prune -------------------------------------------------------
# `--prune` in the same call, not a separate one: forget alone only removes the
# snapshot references, and the data keeps occupying MinIO until a prune runs.
# Two separate scheduled jobs would eventually drift and leave the repository
# growing while everything reported success.
info "retention: ${KEEP_DAILY} daily / ${KEEP_WEEKLY} weekly / ${KEEP_MONTHLY} monthly, per tag"
restic forget \
  --group-by tags \
  --keep-daily "$KEEP_DAILY" \
  --keep-weekly "$KEEP_WEEKLY" \
  --keep-monthly "$KEEP_MONTHLY" \
  --prune \
  --quiet

after="$(restic stats --mode raw-data latest --json 2>/dev/null | jq -r '.total_size // 0')"
ok "repository: ${before} → ${after} bytes"

# --- 2. Weekly integrity check -----------------------------------------------
# `restic check` alone verifies the structure: that every blob a snapshot
# references exists. `--read-data-subset` also re-reads and re-hashes part of
# the actual data, which is the only thing that detects bit rot in MinIO or a
# truncated object. 5% a week covers the whole repository in about five months
# and costs a fraction of the bandwidth of a full read.
if [[ "$(date -u +%u)" == "7" || "${FORCE_CHECK:-0}" == "1" ]]; then
  info "weekly integrity check (structure + 5% of the data re-read)"
  if restic check --read-data-subset=5% ; then
    ok "integrity verified"
  else
    die "restic check FAILED — the repository is damaged. Do not prune again; restore from the off-site mirror and see docs/07-PRA.md."
  fi
else
  log "integrity check: Sundays only (today is day $(date -u +%u))"
fi

job_size "$after"

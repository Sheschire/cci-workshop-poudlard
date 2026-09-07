#!/usr/bin/env bash
# =============================================================================
# offsite-mirror — the "1" of the 3-2-1 rule (CDC §9.1, hourly).
#
#   mc mirror --overwrite --remove minio/restic     offsite/<bucket>-restic
#   mc mirror --overwrite --remove minio/es-snapshots offsite/<bucket>-es
#
# MinIO runs on node3. Everything backed up so far is one node loss away from
# being gone with it: the whole backup chain protects against data loss, not
# against losing the machine that holds the backups. This job is what makes the
# difference between a backup strategy and a directory of archives.
#
# Optional by design (CDC §9.1): with no OFFSITE_S3_* configured the job exits
# 0 and publishes NO metric. Publishing a success would assert that an off-site
# copy exists, which is precisely the lie a backup system must never tell.
# =============================================================================
set -Eeuo pipefail
# The library lives at /opt/backup/lib.sh inside the container; the directive
# below points the linter at its source in the repository.
# shellcheck source=scripts/backup/lib.sh
source /opt/backup/lib.sh

readonly OFFSITE_ENDPOINT="${OFFSITE_S3_ENDPOINT:-}"
readonly OFFSITE_BUCKET="${OFFSITE_S3_BUCKET:-}"

# --- Configured at all? ------------------------------------------------------
# Checked BEFORE job_start, so the EXIT trap is not armed and nothing is
# written to the metrics file.
if [[ -z "$OFFSITE_ENDPOINT" || -z "$OFFSITE_BUCKET" ]]; then
  warn "OFFSITE_S3_ENDPOINT / OFFSITE_S3_BUCKET not set: no off-site copy."
  warn "The 3-2-1 rule is NOT satisfied — losing node3 loses every backup."
  warn "Set OFFSITE_S3_* in .env and redeploy the backup stack (CDC §9.1)."
  exit 0
fi

job_start offsite-mirror

readonly MC_CONFIG_DIR=/tmp/.mc
export MC_CONFIG_DIR

# Aliases through MC_HOST_* environment variables: mc reads them directly, so
# no credential is written to an mc config file and none appears in `ps`.
# The source account is `mirror` — read-only on both buckets by policy
# (config/minio/policies/mirror.json). A mirror job with write access to what
# it mirrors is a ransomware amplifier.
MC_HOST_src="http://$(read_secret dw_minio_mirror_key):$(read_secret dw_minio_mirror_secret)@minio:9000"
MC_HOST_dst="${OFFSITE_ENDPOINT%%://*}://$(read_secret dw_offsite_s3_key):$(read_secret dw_offsite_s3_secret)@${OFFSITE_ENDPOINT#*://}"
export MC_HOST_src MC_HOST_dst

wait_for minio 9000 120 || die "MinIO is not reachable — nothing to mirror"

total=0
mirror_bucket() {
  local source_bucket=$1 target_suffix=$2
  local target="dst/${OFFSITE_BUCKET}-${target_suffix}"

  info "mirroring ${source_bucket} → ${target}"

  # `--remove`: an object deleted locally by `restic forget --prune` is deleted
  # off-site too. Without it the off-site copy grows forever and the retention
  # policy of §9.1 applies to one copy only.
  #
  # The risk of `--remove` is real and accepted: an attacker who deletes the
  # local repository would see the deletion propagate. That is what versioning
  # on the `restic` bucket (scripts/minio-init.sh) and the object-lock or
  # versioning of the off-site provider are for — the mirror is a copy, not an
  # append-only vault, and the PRA says so.
  #
  # `--preserve` keeps modification times, which restic uses when deciding what
  # to re-read on a repository check.
  mc --no-color mirror --overwrite --remove --preserve \
     "src/${source_bucket}" "$target"

  local bytes
  bytes="$(mc --no-color du --json "$target" 2>/dev/null | jq -r '.size // 0' | head -1)"
  total=$(( total + ${bytes:-0} ))
  ok "${source_bucket}: ${bytes:-0} bytes off-site"
}

mirror_bucket restic       restic
mirror_bucket es-snapshots es

job_size "$total"
ok "off-site copy up to date (${total} bytes)"

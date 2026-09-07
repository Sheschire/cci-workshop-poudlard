#!/usr/bin/env bash
# =============================================================================
# backup-glpi-files — the GLPI shared filesystem (CDC §9.1, 02:30 UTC).
#
# GLPI keeps two kinds of state: its database (backed up by backup-galera) and
# its FILES — ticket attachments, configuration, plugins, marketplace. Those
# live on the NFS export of node1 (ADR-0006), which is the platform's only
# single point of failure. This job is half of what makes that SPOF acceptable:
# the data is recoverable within the 24 h RPO of CDC §9.4.
#
# The export is mounted READ-ONLY here. A backup job has no business being able
# to write to what it archives, and an accidental `restic restore` into the
# wrong path would then be impossible rather than merely unlikely.
# =============================================================================
set -Eeuo pipefail
# The library lives at /opt/backup/lib.sh inside the container; the directive
# below points the linter at its source in the repository.
# shellcheck source=scripts/backup/lib.sh
source /opt/backup/lib.sh

job_start backup-glpi-files
restic_env
ensure_repo

readonly SOURCE="${SOURCE:-/data}"

[[ -d "$SOURCE" ]] || die "${SOURCE} is not mounted — check the volumes of stacks/backup.yml"

# An empty source is a red flag, not a small backup: it means the NFS mount
# failed silently and the job would otherwise archive nothing, successfully.
if [[ -z "$(ls -A "$SOURCE" 2>/dev/null)" ]]; then
  die "${SOURCE} is empty — refusing to archive an empty GLPI filesystem"
fi

info "archiving ${SOURCE}"

# --exclude of what is regenerable and voluminous:
#   _cache      GLPI's own file cache, rebuilt on demand
#   _sessions   PHP sessions; restoring them would restore stale logins
#   _tmp        uploads in flight
#   _cron       lock files
#   *.lock      idem, plugin-specific
restic backup "$SOURCE" \
  --tag glpi-files \
  --host dockerwarts \
  --exclude "$SOURCE/files/_cache" \
  --exclude "$SOURCE/files/_sessions" \
  --exclude "$SOURCE/files/_tmp" \
  --exclude "$SOURCE/files/_cron" \
  --exclude "*.lock" \
  --quiet

job_size "$(restic_snapshot_size glpi-files)"
ok "GLPI files archived"

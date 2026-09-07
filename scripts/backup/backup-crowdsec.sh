#!/usr/bin/env bash
# =============================================================================
# backup-crowdsec — the LAPI database (CDC §9.1, 04:30 UTC).
#
# `crowdsec_data` holds the SQLite database of the local API: the decisions
# (who is banned and until when), the machines registered by the agents, the
# bouncer API keys and the alert history. Losing it does not open the platform
# — the firewall rules of layer 1 are still there and CrowdSec re-learns — but
# it drops every active ban at once and forces every agent and bouncer to
# re-register, which is a manual operation on three nodes.
#
# Pinned to node3, where the LAPI runs (CDC §7.2). Volume mounted read-only:
# SQLite is copied, never opened, by this job.
# =============================================================================
set -Eeuo pipefail
# The library lives at /opt/backup/lib.sh inside the container; the directive
# below points the linter at its source in the repository.
# shellcheck source=scripts/backup/lib.sh
source /opt/backup/lib.sh

job_start backup-crowdsec
restic_env
ensure_repo

readonly SOURCE="${SOURCE:-/crowdsec}"

[[ -d "$SOURCE" ]] || die "${SOURCE} is not mounted — check the volumes of stacks/backup.yml"

# The database file is the point of the job; its absence means the volume is
# the wrong one, or CrowdSec has never started.
if ! find "$SOURCE" -name 'crowdsec.db' -type f | grep -q .; then
  die "no crowdsec.db under ${SOURCE} — wrong volume, or the LAPI has never started"
fi

info "archiving ${SOURCE}"

# SQLite is copied while the LAPI may be writing to it. That is acceptable
# HERE and nowhere else on this platform: CrowdSec runs SQLite in WAL mode, so
# a copy is at worst missing the last few seconds of decisions, and a decision
# lost is a ban that CrowdSec re-issues on the next offence. The same shortcut
# on GLPI's database would be a corrupt backup — which is exactly why Galera is
# dumped logically instead.
#
# Excluded: the downloaded hub (scenarios, parsers) is re-fetched on start and
# is several tens of megabytes of content that is already versioned upstream.
restic backup "$SOURCE" \
  --tag crowdsec \
  --host dockerwarts \
  --exclude "$SOURCE/hub" \
  --exclude "*.db-wal" \
  --exclude "*.db-shm" \
  --quiet

job_size "$(restic_snapshot_size crowdsec)"
ok "CrowdSec LAPI archived"

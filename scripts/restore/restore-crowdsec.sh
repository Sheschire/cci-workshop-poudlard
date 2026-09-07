#!/usr/bin/env bash
# =============================================================================
# restore-crowdsec — restore the CrowdSec LAPI database (CDC §9.2).
#
#   scripts/restore/restore-crowdsec.sh [--yes] [snapshot-id]
#
# Must be run on node3, where the LAPI and its volume live.
#
# What comes back: the active decisions (who is banned and until when), the
# registered machines, the bouncer API keys and the alert history.
#
# What this restore is really for: the LAPI is the authority every agent and
# every bouncer registers against. Losing its database does not open the
# platform — the iptables rules of layer 1 are untouched and CrowdSec relearns
# — but it invalidates every credential the agents and the Traefik bouncer
# hold, and re-registering them is a manual operation on three nodes. Restoring
# is minutes; re-registering is an evening.
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

SNAPSHOT="latest"
while (( $# )); do
  case "$1" in
    --yes)     ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        die "unknown option: $1" ;;
    *)         SNAPSHOT="$1"; shift ;;
  esac
done

SNAPSHOT="$(pick_snapshot crowdsec "$SNAPSHOT")"

docker volume inspect edge_crowdsec_data >/dev/null 2>&1 \
  || die "the volume edge_crowdsec_data does not exist on $(hostname) — run this on node3 (crowdsec_lapi=true)"

confirm "About to restore the CrowdSec LAPI database from snapshot ${SNAPSHOT}.
crowdsec-lapi will be stopped, its database REPLACED, and restarted.
Decisions taken since the snapshot will be lost; CrowdSec re-issues them on the
next offence."

# --- 1. Stop the LAPI ---------------------------------------------------------
# SQLite must not be written while its file is being replaced: a restore under
# a live LAPI produces a database with a stale WAL, which SQLite then refuses
# to open — a broken LAPI instead of an outdated one.
#
# While it is down, the agents buffer their alerts and the Traefik bouncer
# keeps serving the decisions it already has in memory (`stream` mode, CDC
# §6.3): the platform stays protected during the restore.
section "Stopping the CrowdSec LAPI"
scale_service edge_crowdsec-lapi 0

restart_lapi() {
  local rc=$?
  section "Restarting the CrowdSec LAPI"
  scale_service edge_crowdsec-lapi 1
  exit "$rc"
}
trap restart_lapi EXIT

elapsed=0
while (( elapsed < 90 )); do
  [[ -z "$(docker ps -q --filter 'label=com.docker.swarm.service.name=edge_crowdsec-lapi' | head -1)" ]] && break
  sleep 3
  elapsed=$(( elapsed + 3 ))
done
ok "LAPI stopped"

# --- 2. Restore ---------------------------------------------------------------
# `--delete` is not used, deliberately: the volume also holds the downloaded
# hub (scenarios and parsers), which the backup excludes because it is
# re-fetched on start. Deleting what the archive does not contain would remove
# it and force a full hub download before CrowdSec can parse anything.
section "Restoring (snapshot ${SNAPSHOT})"
# Expanded inside the container, where /run/secrets exists.
# shellcheck disable=SC2016
restore_script='
  set -Eeuo pipefail
  RESTIC_PASSWORD="$(cat /run/secrets/dw_restic_password)"
  AWS_ACCESS_KEY_ID="$(cat /run/secrets/dw_minio_restic_key)"
  AWS_SECRET_ACCESS_KEY="$(cat /run/secrets/dw_minio_restic_secret)"
  export RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  restic restore "$1" --tag crowdsec --target /restore
  src="$(find /restore -type d -name crowdsec | head -1)"
  [ -n "$src" ] || { echo "no crowdsec directory in the archive" >&2; exit 1; }
  cp -a "$src"/. /crowdsec/
  # A stale WAL or shared-memory file next to a restored database makes SQLite
  # refuse to open it. They are excluded from the backup for that reason, and
  # removed here in case an older archive carries them.
  rm -f /crowdsec/data/crowdsec.db-wal /crowdsec/data/crowdsec.db-shm
  find /crowdsec -name crowdsec.db -exec ls -l {} \; >&2
'
RESTORE_MOUNTS=(-v "edge_crowdsec_data:/crowdsec")
runner_restore bash -c "$restore_script" _ "$SNAPSHOT" \
  || die "the restore FAILED — CrowdSec will restart with whatever is left in the volume"
ok "database restored"

section "Restore complete"
ok "snapshot ${SNAPSHOT} restored — the LAPI is being restarted"
ok "check with: docker exec <lapi> cscli decisions list"

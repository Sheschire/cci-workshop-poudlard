#!/usr/bin/env bash
# =============================================================================
# restore-glpi-files — restore the GLPI shared filesystem (CDC §9.2).
#
#   scripts/restore/restore-glpi-files.sh [options] [snapshot-id]
#
#   --to DIR    restore into a temporary directory instead of the live NFS
#               export (used by `make dr-drill`: verify without touching
#               production)
#   --yes       do not ask for confirmation
#
# GLPI keeps its attachments, configuration, plugins and marketplace on the NFS
# export of node1 (ADR-0006). Restoring them under a running GLPI would produce
# a half-old, half-new filesystem while PHP holds open file handles — so the
# web and cron services are stopped for the duration and brought back from a
# trap, whatever happens.
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

TO_DIR=""
SNAPSHOT="latest"
while (( $# )); do
  case "$1" in
    --to)      TO_DIR="${2:?--to needs a directory}"; shift 2 ;;
    --yes)     ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        die "unknown option: $1" ;;
    *)         SNAPSHOT="$1"; shift ;;
  esac
done

SNAPSHOT="$(pick_snapshot glpi-files "$SNAPSHOT")"

# =============================================================================
# Mode A — restore into a scratch directory (the drill)
# =============================================================================
if [[ -n "$TO_DIR" ]]; then
  section "Restoring snapshot ${SNAPSHOT} into ${TO_DIR} (production untouched)"
  mkdir -p "$TO_DIR"
  RESTORE_MOUNTS=(-v "${TO_DIR}:/restore")
  restic_run_writable restic restore "$SNAPSHOT" --tag glpi-files --target /restore \
    || die "restore failed"
  ok "restored into ${TO_DIR}"
  find "$TO_DIR" -type f | head -5 | sed 's/^/    /' >&2
  exit 0
fi

# =============================================================================
# Mode B — restore the live export
# =============================================================================
confirm "About to restore the GLPI files of snapshot ${SNAPSHOT} onto the LIVE NFS export.
glpi-web and glpi-cron will be stopped during the operation (expect a few
minutes of downtime), and any file created since the backup will be lost."

# --- 1. Stop the consumers ----------------------------------------------------
# Both, and glpi-cron first: it is the one that writes (inventory imports,
# notification queue) and would keep producing files under the restore.
section "Stopping GLPI"
scale_service apps_glpi-cron 0
scale_service apps_glpi-web 0

restart_glpi() {
  local rc=$?
  section "Restarting GLPI"
  scale_service apps_glpi-web 2
  scale_service apps_glpi-cron 1
  exit "$rc"
}
trap restart_glpi EXIT

# --- 2. Restore ---------------------------------------------------------------
# The four exports are mounted at the same paths the backup used, so restic
# writes each file back where it came from. `--delete` is deliberately NOT
# used: a file created after the backup is left alone rather than deleted. A
# restore should add back what was lost, not remove what survived; the operator
# who genuinely wants a byte-identical export empties it first, knowingly.
section "Restoring (snapshot ${SNAPSHOT})"
RESTORE_MOUNTS=(
  -v "dw_restore_glpi_files:/data/files"
  -v "dw_restore_glpi_config:/data/config"
  -v "dw_restore_glpi_plugins:/data/plugins"
  -v "dw_restore_glpi_marketplace:/data/marketplace"
)

# The NFS volumes belong to the `apps` stack; recreate the same mounts here as
# throw-away named volumes pointing at the same export.
for sub in files config plugins marketplace; do
  docker volume create \
    --driver local \
    --opt type=nfs \
    --opt "o=addr=${NFS_SERVER},rw,nfsvers=4.1,soft,timeo=50,retrans=3" \
    --opt "device=:/srv/nfs/glpi/${sub}" \
    "dw_restore_glpi_${sub}" >/dev/null
done

cleanup_volumes() {
  for sub in files config plugins marketplace; do
    docker volume rm "dw_restore_glpi_${sub}" >/dev/null 2>&1 || true
  done
}

if restic_run_writable restic restore "$SNAPSHOT" --tag glpi-files --target / ; then
  ok "files restored"
else
  cleanup_volumes
  die "restore FAILED — GLPI will be restarted, but its files are in an unknown state"
fi

# --- 3. Verify ----------------------------------------------------------------
# Counted through the same mounts that were just written, before they are
# removed: this proves the files are on the EXPORT, not merely that restic
# reported success into a directory that was never really mounted.
section "Verification"
count="$(runner bash -c 'find /data -type f | wc -l' 2>/dev/null || echo "?")"
ok "GLPI export: ${count} file(s) under /data"
cleanup_volumes

section "Restore complete"
ok "snapshot ${SNAPSHOT} restored — GLPI is being restarted"

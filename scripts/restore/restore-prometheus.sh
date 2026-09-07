#!/usr/bin/env bash
# =============================================================================
# restore-prometheus — restore the TSDB of instance A (CDC §9.2).
#
#   scripts/restore/restore-prometheus.sh [--yes] [snapshot-id]
#
# Must be run on the node labelled prometheus=a, which is where the volume is.
#
# Prometheus must be STOPPED for this. A TSDB is not a set of independent
# files: the head block lives in memory, the WAL is being appended, and
# replacing blocks under a running Prometheus produces a database it will
# refuse to open at the next restart — discovered hours later, when the process
# is finally restarted for an unrelated reason.
#
# Only instance A is restored. Instance B keeps scraping throughout: metrics
# collection never stops, which is the point of HA by duplication. B's own
# history is not affected and, since both scrape the same targets, the two
# converge again as soon as A is back.
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
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        die "unknown option: $1" ;;
    *)         SNAPSHOT="$1"; shift ;;
  esac
done

SNAPSHOT="$(pick_snapshot prometheus "$SNAPSHOT")"

# The volume is node-local: this only works where instance A runs.
docker volume inspect monitoring_prometheus_data >/dev/null 2>&1 \
  || die "the volume monitoring_prometheus_data does not exist on $(hostname) — run this on the node labelled prometheus=a"

confirm "About to restore the Prometheus TSDB of instance A from snapshot ${SNAPSHOT}.
Instance A will be stopped, its data directory REPLACED, and restarted.
Every metric scraped by A since the snapshot will be lost (instance B keeps its own)."

# --- 1. Stop instance A, and ONLY instance A ---------------------------------
# Scaling the service down is not usable here: `--replicas 1` lets Swarm choose
# which of the two tasks to stop, and it may well stop B. `--replicas 0` stops
# both, which throws away the whole point of HA by duplication during the very
# operation that needs the other instance to keep scraping.
#
# The deterministic lever is the placement label. The service is constrained on
# `node.labels.prometheus != ""` with max_replicas_per_node 1, so removing the
# label from THIS node makes its task unschedulable — Swarm stops it and cannot
# move it to node2, where B already holds the only other slot. B keeps running
# throughout; monitoring never stops.
#
# The label is put back by the trap, so an interrupted restore does not leave
# this node permanently out of the Prometheus placement.
section "Stopping Prometheus instance A"
NODE_ID="$(docker info --format '{{.Swarm.NodeID}}')"
PROM_LABEL="$(docker node inspect "$NODE_ID" --format '{{index .Spec.Labels "prometheus"}}')"
[[ -n "$PROM_LABEL" ]] \
  || die "this node carries no 'prometheus' label — run this on the node labelled prometheus=a"
info "node $(hostname) carries prometheus=${PROM_LABEL}"

docker node update --label-rm prometheus "$NODE_ID" >/dev/null
ok "placement label removed: the local task is being stopped"

restore_label_and_restart() {
  local rc=$?
  section "Restoring the placement label and restarting instance A"
  docker node update --label-add "prometheus=${PROM_LABEL}" "$NODE_ID" >/dev/null \
    || error "COULD NOT RESTORE the label prometheus=${PROM_LABEL} on $(hostname) — do it by hand NOW: docker node update --label-add prometheus=${PROM_LABEL} ${NODE_ID}"
  exit "$rc"
}
trap restore_label_and_restart EXIT

# `docker node update` returns before the task has actually stopped, and
# restoring under a dying Prometheus is precisely the corruption this avoids.
elapsed=0
while (( elapsed < 120 )); do
  [[ -z "$(docker ps -q --filter 'label=com.docker.swarm.service.name=monitoring_prometheus' | head -1)" ]] && break
  sleep 3
  elapsed=$(( elapsed + 3 ))
done
[[ -z "$(docker ps -q --filter 'label=com.docker.swarm.service.name=monitoring_prometheus' | head -1)" ]] \
  || die "the local Prometheus task is still running after 120 s — aborting rather than restoring under it"
ok "instance A stopped, instance B still scraping"

# --- 2. Empty the data directory ---------------------------------------------
# A restore that merges into an existing TSDB gives Prometheus two sets of
# blocks covering the same time ranges. It starts, and then reports duplicate
# samples on every query touching the overlap. The directory is emptied first —
# which is what makes this operation destructive, and why it asks.
section "Emptying the current TSDB"
RESTORE_MOUNTS=(-v "monitoring_prometheus_data:/prometheus")
runner_restore bash -c 'rm -rf /prometheus/* /prometheus/.[!.]* 2>/dev/null; ls -A /prometheus | wc -l' \
  || die "could not empty the data directory"
ok "data directory emptied"

# --- 3. Restore ---------------------------------------------------------------
# The archive contains .../snapshots/<name>/<blocks>. Prometheus expects the
# blocks at the ROOT of its data directory, so they are moved up one level
# after the restore — restoring the snapshots/ tree verbatim would give
# Prometheus an empty database and no error.
section "Restoring (snapshot ${SNAPSHOT})"
# Expanded inside the container, where /run/secrets exists.
# shellcheck disable=SC2016
restore_script='
  set -Eeuo pipefail
  RESTIC_PASSWORD="$(cat /run/secrets/dw_restic_password)"
  AWS_ACCESS_KEY_ID="$(cat /run/secrets/dw_minio_restic_key)"
  AWS_SECRET_ACCESS_KEY="$(cat /run/secrets/dw_minio_restic_secret)"
  export RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  restic restore "$1" --tag prometheus --target /restore
  snap_dir="$(find /restore -type d -name "20*" -path "*/snapshots/*" | head -1)"
  [ -n "$snap_dir" ] || { echo "no snapshot directory in the archive" >&2; exit 1; }
  echo "moving the blocks of $snap_dir into place" >&2
  cp -a "$snap_dir"/. /prometheus/
  chown -R 65534:65534 /prometheus
  ls -1 /prometheus | head -10 >&2
'
RESTORE_MOUNTS=(-v "monitoring_prometheus_data:/prometheus")
runner_restore bash -c "$restore_script" _ "$SNAPSHOT" \
  || die "the restore FAILED — the TSDB is empty; Prometheus will restart and begin a fresh database"
ok "blocks restored"

section "Restore complete"
ok "snapshot ${SNAPSHOT} restored — Prometheus is being restarted"
ok "check with: curl -s http://prometheus:9090/api/v1/query?query=up | jq"

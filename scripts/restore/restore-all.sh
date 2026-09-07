#!/usr/bin/env bash
# =============================================================================
# restore-all — restore the whole platform, in the right order (CDC §9.2, §9.6).
#
#   scripts/restore/restore-all.sh [options]
#
#   --from offsite   pull the repositories back from the off-site S3 first
#   --list           list what is available in the repository, restore nothing
#   --skip NAME      skip one component (repeatable): galera, glpi-files,
#                    cassandra, es, crowdsec, prometheus
#   --yes            do not ask for confirmation at each step (unattended)
#
# This is step 5 of the full rebuild of CDC §9.6. It assumes the platform is
# already standing and EMPTY: hosts provisioned, Swarm formed, secrets restored
# from the vault, `edge` and `data` deployed.
#
# The order is not a preference
# -----------------------------
#   1. Galera        GLPI's installer and Grafana both refuse to start without
#                    their database; everything downstream waits on it.
#   2. GLPI files    must be in place before glpi-web is allowed to serve, or
#                    GLPI regenerates a config and considers itself a fresh
#                    install.
#   3. Cassandra     independent of the above; long, so it starts early.
#   4. Elasticsearch idem, and Kibana's saved objects depend on it.
#   5. CrowdSec      before the platform is exposed: restoring the decisions
#                    after opening the door defeats the point.
#   6. Prometheus    last, and openly optional: metrics history is the only
#                    thing on this platform nobody is blocked by (CDC §9.4
#                    accepts a 7-day RPO).
#
# Each step is delegated to its own script, so a component can equally be
# restored on its own — which is what actually happens in most incidents.
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

readonly HERE="${DW_ROOT}/scripts/restore"
FROM_OFFSITE=0
LIST=0
SKIP=()
YES_ARG=()
while (( $# )); do
  case "$1" in
    --from)    [[ "${2:-}" == "offsite" ]] || die "--from only accepts 'offsite'"; FROM_OFFSITE=1; shift 2 ;;
    --list)    LIST=1; shift ;;
    --skip)    SKIP+=("${2:?--skip needs a component name}"); shift 2 ;;
    --yes)     ASSUME_YES=1; YES_ARG=(--yes); shift ;;
    -h|--help) sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         die "unknown option: $1" ;;
  esac
done

skipped() {
  local name=$1 s
  for s in "${SKIP[@]}"; do [[ "$s" == "$name" ]] && return 0; done
  return 1
}

# =============================================================================
# --list — what can be restored, and how old it is
# =============================================================================
if (( LIST )); then
  section "restic snapshots"
  restic_run snapshots --compact || die "cannot read the repository — is MinIO up? are the secrets restored?"
  section "Elasticsearch snapshots"
  "${HERE}/restore-es.sh" --list || warn "Elasticsearch is not reachable"
  exit 0
fi

# =============================================================================
# --from offsite — bring the repositories back before restoring anything
#
# The scenario this exists for: node3 is gone, and with it MinIO and every
# local copy. A fresh MinIO has been redeployed and is empty. Nothing can be
# restored until the buckets are refilled from the only surviving copy.
# =============================================================================
if (( FROM_OFFSITE )); then
  section "Re-synchronising from the off-site S3"
  [[ -n "${OFFSITE_S3_ENDPOINT:-}" && -n "${OFFSITE_S3_BUCKET:-}" ]] \
    || die "OFFSITE_S3_ENDPOINT / OFFSITE_S3_BUCKET are not set in .env — there is no off-site copy to pull from"

  confirm "About to OVERWRITE the local MinIO buckets with the off-site copy.
Anything in MinIO that is not off-site will be lost."

  # Direction reversed compared with the mirror job: off-site → local. Root
  # credentials, because the `mirror` account is read-only by policy and this
  # is the one operation that must write into the buckets.
  RESTORE_SECRETS=(dw_minio_root_user dw_minio_root_password dw_offsite_s3_key dw_offsite_s3_secret)
  # Expanded inside the container, where /run/secrets exists.
  # shellcheck disable=SC2016
  pull_script='
    set -Eeuo pipefail
    endpoint="$1"; bucket="$2"
    MC_HOST_local="http://$(cat /run/secrets/dw_minio_root_user):$(cat /run/secrets/dw_minio_root_password)@minio:9000"
    scheme="${endpoint%%://*}"
    host="${endpoint#*://}"
    MC_HOST_offsite="${scheme}://$(cat /run/secrets/dw_offsite_s3_key):$(cat /run/secrets/dw_offsite_s3_secret)@${host}"
    export MC_HOST_local MC_HOST_offsite MC_CONFIG_DIR=/tmp/.mc
    mc --no-color mb --ignore-existing local/restic local/es-snapshots
    mc --no-color mirror --overwrite --preserve "offsite/${bucket}-restic"  local/restic
    mc --no-color mirror --overwrite --preserve "offsite/${bucket}-es"      local/es-snapshots
    mc --no-color du local/restic local/es-snapshots
  '
  runner bash -c "$pull_script" _ "$OFFSITE_S3_ENDPOINT" "$OFFSITE_S3_BUCKET" \
    || die "the off-site re-synchronisation FAILED — nothing has been restored"
  ok "buckets re-synchronised from the off-site copy"
  RESTORE_SECRETS=(dw_restic_password dw_minio_restic_key dw_minio_restic_secret)
fi

# =============================================================================
# The sequence
# =============================================================================
report_init restore-all "Restauration complète — \`restore-all.sh\`"
report '| Étape | Composant | Résultat |'
report '|---|---|---|'

step=0
failed=()
run_step() {
  local name=$1; shift
  step=$(( step + 1 ))
  if skipped "$name"; then
    warn "${name}: skipped on request"
    report "| ${step} | ${name} | ⏭️ ignoré |"
    return 0
  fi
  section "Step ${step}/6 — ${name}"
  if "$@"; then
    ok "${name} restored"
    report "| ${step} | ${name} | ✅ |"
    return 0
  fi
  error "${name} FAILED"
  report "| ${step} | ${name} | ❌ |"
  failed+=("$name")
  # Deliberately NOT fatal: a failure on Cassandra must not stop the
  # Elasticsearch restore. During a rebuild, every component that CAN come back
  # should come back, and the operator deals with the rest — a half-restored
  # platform is strictly better than one stopped at the first error.
  return 0
}

run_step galera      "${HERE}/restore-galera.sh"      "${YES_ARG[@]}"
run_step glpi-files  "${HERE}/restore-glpi-files.sh"  "${YES_ARG[@]}"
# The three Cassandra snapshots hold overlapping copies of the same rows
# (RF=3). Loading all three is not wasted work: it is what guarantees that
# whatever was lost on one node is recovered from another, and Cassandra
# resolves the duplicates by write timestamp.
for n in 1 2 3; do
  run_step "cassandra" "${HERE}/restore-cassandra.sh" "$n" "${YES_ARG[@]}"
done
run_step es          "${HERE}/restore-es.sh"          "${YES_ARG[@]}"
run_step crowdsec    "${HERE}/restore-crowdsec.sh"    "${YES_ARG[@]}"
run_step prometheus  "${HERE}/restore-prometheus.sh"  "${YES_ARG[@]}"

# =============================================================================
# Validation
#
# A restore is not finished when the data is back; it is finished when the
# platform works. `make smoke` walks the published hostnames through the VIP —
# the same check an operator would do by hand, only complete.
# =============================================================================
section "Validation"
if [[ -x tests/smoke/smoke.sh ]]; then
  if tests/smoke/smoke.sh; then
    ok "smoke test green"
    report ''
    # Markdown code span, not a command substitution.
    # shellcheck disable=SC2016
    report '**Validation `make smoke` : ✅**'
  else
    error "smoke test FAILED — the data is back but the platform is not serving"
    report ''
    # shellcheck disable=SC2016
    report '**Validation `make smoke` : ❌**'
    failed+=("smoke")
  fi
else
  warn "tests/smoke/smoke.sh not available — validate by hand (docs/07-PRA.md)"
fi

section "Summary"
if (( ${#failed[@]} == 0 )); then
  ok "the platform is restored and serving"
  exit 0
fi
error "${#failed[@]} step(s) failed: ${failed[*]}"
error "see docs/07-PRA.md for the per-component procedures"
exit 1

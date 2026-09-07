#!/usr/bin/env bash
# =============================================================================
# `make chaos` — the full HA campaign (CDC §8.2).
#
#   tests/chaos/run-all.sh [--no-node-kill] [--quick]
#
#   --no-node-kill   skip the `vagrant halt` scenarios (when running FROM a
#                    node rather than from the workstation)
#   --quick          services and one drain only — the loop used while
#                    developing, not the campaign
#
# Order, and why it is this one
# -----------------------------
# From the least to the most destructive, so that a failure is diagnosed on the
# smallest scenario that shows it. Killing a node first and finding the platform
# broken tells you nothing about which layer failed.
#
#   1. tasks        Swarm reschedules — no state involved
#   2. drain        a node leaves POLITELY: the datastores shut down cleanly
#   3. kill node2   the brutal loss of an ordinary node
#   4. kill node3   the loss of MinIO and the CrowdSec LAPI
#   5. kill node1   the brutal loss of the NFS holder — the assumed SPOF, and
#                   the scenario that must be documented rather than passed
#
# The platform must be nominal between two scenarios; run-all waits for that
# and refuses to continue on a cluster it could not bring back — measurements
# taken on a degraded platform describe the previous scenario, not this one.
#
# Produces the single Markdown table docs/06-haute-disponibilite.md quotes.
# =============================================================================
set -Eeuo pipefail
# Paths are relative to --source-path=scripts (see the lint-shell target).
# shellcheck source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh"
# shellcheck source=../tests/chaos/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

load_env
cd "$DW_ROOT"

readonly HERE="${DW_ROOT}/tests/chaos"
NODE_KILL=1
QUICK=0
while (( $# )); do
  case "$1" in
    --no-node-kill) NODE_KILL=0; shift ;;
    --quick)        QUICK=1; shift ;;
    -h|--help)      sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              die "unknown option: $1" ;;
  esac
done

# `vagrant halt` needs Vagrant. Rather than failing halfway through the
# campaign, the node scenarios are dropped up front, with a clear message.
if (( NODE_KILL )) && ! command -v vagrant >/dev/null 2>&1; then
  warn "vagrant absent : les scénarios de perte de nœud sont ignorés."
  warn "  Ils s'exécutent depuis le POSTE D'ADMINISTRATION, pas depuis un nœud."
  NODE_KILL=0
fi

report_init chaos "Campagne de tests HA — \`make chaos\`"
report 'Chaque scénario mesure l'"'"'indisponibilité **réelle** à travers la VIP'
report '(sonde à 5 Hz, plus longue série d'"'"'échecs consécutifs), vérifie l'"'"'état des'
report 'clusters et rejoue le test de fumée. La plateforme est ramenée à son état'
report 'nominal entre deux scénarios.'
report ''
chaos_report_header

FAILED=()
RUN=0

# -----------------------------------------------------------------------------
# scenario <label> <command…> — run one scenario and keep going on failure.
#
# A campaign that stops at the first failure hides the others; the exit code at
# the end is what fails the build.
# -----------------------------------------------------------------------------
scenario() {
  local label=$1; shift
  RUN=$(( RUN + 1 ))
  section "Scénario ${RUN} — ${label}"
  if "$@"; then
    ok "${label}"
  else
    error "${label} : ÉCHEC"
    FAILED+=("$label")
  fi

  # Between two scenarios the platform must be nominal again. Not waiting is
  # how a campaign produces a report full of numbers that describe the wrong
  # thing. `|| true` because the diagnosis belongs to the next scenario, which
  # will fail loudly with its own measurements.
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    wait_converged 300 || warn "plateforme non revenue à l'état nominal avant le scénario suivant"
  fi
}

# =============================================================================
# 1. Loss of a task
#
# Three services, chosen because they fail differently:
#   glpi-web    2 replicas behind a sticky cookie — the user-visible one
#   traefik     global and stateless, but it is the entry point itself
#   galera-2    a STATEFUL member: it must rejoin by IST, not by a full SST
# =============================================================================
scenario "Perte d'une tâche — apps_glpi-web"  "${HERE}/kill-service.sh" apps_glpi-web
scenario "Perte d'une tâche — edge_traefik"   "${HERE}/kill-service.sh" edge_traefik
scenario "Perte d'une tâche — data_galera-2"  "${HERE}/kill-service.sh" data_galera-2

# A rolling update, i.e. what every deployment does. With `start-first` it must
# cost nothing at all; this is the scenario that catches an `update_config`
# regression before it is discovered during a release.
scenario "Mise à jour glissante — apps_glpi-web" \
  "${HERE}/kill-service.sh" apps_glpi-web --force-update

# =============================================================================
# 2. Planned drain
# =============================================================================
scenario "Drain planifié — node2" "${HERE}/drain-node.sh" node2

if (( QUICK )); then
  warn "--quick : scénarios de perte de nœud ignorés"
  NODE_KILL=0
fi

# =============================================================================
# 3. Brutal loss of a node
#
# node1 comes LAST on purpose. It carries the NFS export (ADR-0006) and its
# loss degrades GLPI; running it earlier would leave every following scenario
# measuring a platform whose attachments are broken.
# =============================================================================
if (( NODE_KILL )); then
  scenario "Perte brutale — node2"                "${HERE}/kill-node.sh" node2
  scenario "Perte brutale — node3 (MinIO, LAPI)"  "${HERE}/kill-node.sh" node3
  scenario "Perte brutale — node1 (porteur NFS)"  "${HERE}/kill-node.sh" node1
fi

# =============================================================================
# Background load (CDC §8.2, n°5)
# =============================================================================
section "Charge de fond"
errors="$(demo_producer_errors)"
report ''
if [[ "$errors" == "n/a" ]]; then
  warn "demo-producer non déployé : le critère « compteur d'erreurs à zéro » n'a pas été mesuré."
  warn "  Le déployer avant la campagne : make deploy-demo"
  report "> ⚠️ \`demo-producer\` non déployé pendant la campagne : le compteur d'erreurs"
  report "> Cassandra/Elasticsearch n'a pas pu être mesuré (CDC §8.2 n°5)."
elif [[ "$errors" == "0" ]]; then
  ok "demo-producer : 0 erreur pendant toute la campagne"
  report "> ✅ \`demo-producer\` : **0 erreur** d'écriture Cassandra/Elasticsearch pendant"
  report "> toute la campagne — la production ne s'est pas interrompue."
else
  error "demo-producer : ${errors} erreur(s) pendant la campagne"
  report "> ❌ \`demo-producer\` : **${errors} erreurs** d'écriture pendant la campagne."
  FAILED+=("demo-producer: ${errors} erreurs")
fi

# =============================================================================
section "Résumé de la campagne"
report ''
if (( ${#FAILED[@]} == 0 )); then
  ok "${RUN} scénarios, 0 échec"
  report "**Résultat : ${RUN} scénarios exécutés, 0 échec.**"
  report ''
  # Markdown code span, not a command substitution.
  # shellcheck disable=SC2016
  report 'Tableau à recopier dans [`docs/06-haute-disponibilite.md`](../docs/06-haute-disponibilite.md).'
  info "rapport : ${DW_REPORT}"
  exit 0
fi
error "${#FAILED[@]} scénario(s) en échec sur ${RUN} : ${FAILED[*]}"
report "**Résultat : ${#FAILED[@]} échec(s) sur ${RUN} — ${FAILED[*]}.**"
info "rapport : ${DW_REPORT}"
exit 1

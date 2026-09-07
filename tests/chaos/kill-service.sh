#!/usr/bin/env bash
# =============================================================================
# kill-service.sh — kill a task and watch Swarm put it back (CDC §8.2, n°1).
#
#   tests/chaos/kill-service.sh <service> [--force-update]
#
#   <service>        full Swarm name, e.g. edge_traefik, apps_glpi-web
#   --force-update   `docker service update --force` (rolling) instead of
#                    killing a container outright
#
# The two failures are not the same, and both are worth testing:
#
#   kill        the abrupt one. A container disappears without warning, as it
#               would on an OOM kill or a segfault. Swarm notices, reschedules,
#               and the question is how long the service is degraded.
#   --force     the planned one. A rolling update, which is what every
#               deployment does. `update_config.order` decides whether there is
#               a gap: `start-first` should show none at all.
#
# Measures the real unavailability through the VIP, waits for convergence, and
# runs the smoke test. Called by run-all.sh for a representative set of
# services; usable on its own for any of them.
# =============================================================================
set -Eeuo pipefail
# Paths are relative to --source-path=scripts (see the lint-shell target).
# shellcheck source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh"
# shellcheck source=../tests/chaos/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

need_manager
load_env
cd "$DW_ROOT"

SERVICE="${1:?usage: kill-service.sh <service> [--force-update]}"
MODE="kill"
[[ "${2:-}" == "--force-update" ]] && MODE="force"

docker service inspect "$SERVICE" >/dev/null 2>&1 \
  || die "unknown service: ${SERVICE} (docker service ls)"

# Standalone runs get their own report; run-all.sh sets DW_REPORT and appends.
if [[ -z "${DW_REPORT:-}" ]]; then
  report_init "chaos-kill-service" "Chaos — perte d'une tâche (\`${SERVICE}\`)"
  chaos_report_header
fi

section "Scenario: ${MODE} ${SERVICE}"

replicas_before="$(docker service ls --filter "name=${SERVICE}" --format '{{.Replicas}}' | head -1)"
tickets_before="$(glpi_ticket_count)"
info "before: ${SERVICE} ${replicas_before}, ${tickets_before} ticket(s)"

# -----------------------------------------------------------------------------
do_kill() {
  # The task is killed wherever it runs, including on another node: chaos that
  # only ever hits the local node is not chaos, it is a local restart.
  local target_node
  target_node="$(
    docker service ps "$SERVICE" --filter 'desired-state=running' \
      --format '{{.Node}}' --no-trunc | head -1
  )"
  [[ -n "${target_node:-}" ]] || die "no running task for ${SERVICE}"
  info "killing a task of ${SERVICE} on ${target_node}"

  local local_cid
  local_cid="$(docker ps -q --filter "label=com.docker.swarm.service.name=${SERVICE}" | head -1)"
  if [[ -n "$local_cid" ]]; then
    # SIGKILL, not `docker stop`: a graceful stop tests the shutdown path, and
    # what needs testing here is the ungraceful one.
    docker kill --signal=KILL "$local_cid" >/dev/null
    ok "task killed locally (${local_cid:0:12})"
  else
    # No task here. `docker service update --force` reschedules from a manager
    # without needing a shell on the node that holds it — this is why the
    # campaign is runnable from a single manager.
    warn "no local task; forcing a rescheduling from this manager instead"
    docker service update --detach=true --force "$SERVICE" >/dev/null
  fi
}

do_force() {
  info "rolling update of ${SERVICE}"
  docker service update --detach=false --force "$SERVICE" >/dev/null 2>&1 || true
}

# -----------------------------------------------------------------------------
if [[ "$MODE" == "kill" ]]; then
  downtime="$(measure_downtime do_kill)"
else
  downtime="$(measure_downtime do_force)"
fi
info "measured unavailability: ${downtime}s"

wait_converged 180 || true
replicas_after="$(docker service ls --filter "name=${SERVICE}" --format '{{.Replicas}}' | head -1)"
smoke_result="$(run_smoke)"
errors="$(demo_producer_errors)"
tickets_after="$(glpi_ticket_count)"

# -----------------------------------------------------------------------------
# Verdict.
#
# The bar is deliberately different for the two modes. A killed task on a
# 2-replica service should cost nothing at all through the VIP — the other
# replica serves. A rolling update with `start-first` should likewise cost
# nothing. Any measurable outage on a replicated, stateless service is a
# finding, so the threshold is generous but not infinite: 5 s, the same figure
# the CDC uses for the VIP failover.
verdict="✅"
notes=""
[[ "$smoke_result" == "vert" ]] || { verdict="❌"; notes+="smoke ROUGE; "; }
[[ "$replicas_after" == "$replicas_before" ]] || { verdict="❌"; notes+="replicas ${replicas_before}→${replicas_after}; "; }
awk -v d="$downtime" 'BEGIN { exit (d > 5.0) ? 0 : 1 }' && { verdict="❌"; notes+="indispo > 5 s; "; }
[[ "$errors" == "n/a" || "$errors" == "0" ]] || { verdict="⚠️"; notes+="demo-producer: ${errors} erreurs; "; }

chaos_report_row \
  "Perte d'une tâche — \`${SERVICE}\` (${MODE})" \
  "kill-service.sh ${SERVICE}" \
  "reschedule Swarm, service servi en continu" \
  "replicas ${replicas_before} → ${replicas_after}, smoke ${smoke_result}${notes:+, ${notes%; }}" \
  "${downtime} s" \
  "$([[ "$tickets_after" != "$tickets_before" ]] && echo "oui (${tickets_before}→${tickets_after})" || echo "non")" \
  "$verdict"

section "Result"
if [[ "$verdict" == "❌" ]]; then
  error "${SERVICE}: ${notes%; }"
  exit 1
fi
ok "${SERVICE}: unavailability ${downtime}s, smoke ${smoke_result}"

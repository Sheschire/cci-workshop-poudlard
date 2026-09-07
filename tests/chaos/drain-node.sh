#!/usr/bin/env bash
# =============================================================================
# drain-node.sh — planned maintenance on a node (CDC §8.2, n°2).
#
#   tests/chaos/drain-node.sh <node> [--hold SECONDS]
#
#   <node>          Swarm hostname (node1, node2, node3)
#   --hold N        stay drained for N seconds (default 60)
#
# `drain` is the polite failure: Swarm is TOLD the node is leaving, so it stops
# its tasks and reschedules them. It is what a kernel upgrade looks like, and it
# is the scenario an operator will actually run — which is why it is tested
# before the brutal one.
#
# What it proves that kill-node.sh cannot: the stateful services behave
# correctly when their node leaves *gracefully*. Galera performs a clean
# shutdown (no SST on return, an IST is enough), Cassandra flushes its memtables
# on SIGTERM, Elasticsearch reallocates its shards in an orderly fashion. The
# cluster states are checked WHILE the node is drained — a cluster that only
# looks healthy once everything is back proves nothing.
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

NODE="${1:?usage: drain-node.sh <node> [--hold SECONDS]}"
HOLD=60
[[ "${2:-}" == "--hold" ]] && HOLD="${3:?--hold needs a duration}"

docker node inspect "$NODE" >/dev/null 2>&1 || die "unknown node: ${NODE} (docker node ls)"

if [[ -z "${DW_REPORT:-}" ]]; then
  report_init "chaos-drain-node" "Chaos — mise en drain de \`${NODE}\`"
  chaos_report_header
fi

section "Scenario: drain ${NODE} for ${HOLD}s"

tickets_before="$(glpi_ticket_count)"

# The node is put back IN SERVICE whatever happens — including a Ctrl-C or a
# failure in the middle of the checks. A chaos test that leaves the cluster
# degraded is worse than no chaos test.
restore_node() {
  local rc=$?
  section "Returning ${NODE} to service"
  docker node update --availability active "$NODE" >/dev/null 2>&1 \
    || error "COULD NOT reactivate ${NODE} — do it now: docker node update --availability active ${NODE}"
  exit "$rc"
}
trap restore_node EXIT

do_drain() {
  docker node update --availability drain "$NODE" >/dev/null
  ok "${NODE} drained"
  sleep "$HOLD"
}

downtime="$(CHAOS_SETTLE=10 measure_downtime do_drain)"
info "measured unavailability during the drain: ${downtime}s"

# =============================================================================
# Cluster state WHILE the node is drained
#
# This is the point of the scenario. Two of three members left, and the CDC's
# promise is that the platform keeps serving with a quorum — Galera Primary at
# size 2, Cassandra with 2 UN, Elasticsearch yellow (replicas unassigned) but
# never red.
# =============================================================================
section "Cluster state with ${NODE} drained"

galera_size="?"
galera_cid="$(docker ps -q --filter 'label=com.docker.swarm.service.name=data_galera-1' | head -1)"
if [[ -n "$galera_cid" ]]; then
  # shellcheck disable=SC2016  # $(cat …) must expand INSIDE the container
  galera_size="$(docker exec "$galera_cid" sh -c \
    'mariadb -u root -p"$(cat /run/secrets/dw_mariadb_root_password)" -N -B \
       -e "SHOW STATUS LIKE '"'"'wsrep_cluster_size'"'"';"' 2>/dev/null | awk '{print $2}')"
  log "Galera wsrep_cluster_size = ${galera_size:-?}"
fi

cass_un="?"
cass_cid="$(docker ps -q --filter 'label=com.docker.swarm.service.name=data_cassandra-1' | head -1)"
if [[ -n "$cass_cid" ]]; then
  cass_un="$(docker exec "$cass_cid" nodetool status 2>/dev/null | awk '$1 == "UN" {n++} END {print n+0}')"
  log "Cassandra nœuds UN = ${cass_un}"
fi

es_health="?"
es_cid="$(docker ps -q --filter 'label=com.docker.swarm.service.name=data_es-1' | head -1)"
if [[ -n "$es_cid" ]]; then
  # shellcheck disable=SC2016
  es_health="$(docker exec "$es_cid" sh -c \
    'curl -s -u "elastic:$(cat /run/secrets/dw_es_elastic_password)" \
       localhost:9200/_cluster/health' 2>/dev/null | jq -r '.status // "?"')"
  log "Elasticsearch health = ${es_health}"
fi

smoke_drained="$(run_smoke)"
errors_drained="$(demo_producer_errors)"

# =============================================================================
# Back in service
# =============================================================================
section "Returning ${NODE} to service"
docker node update --availability active "$NODE" >/dev/null
trap - EXIT
ok "${NODE} active"

wait_converged 300 || true
smoke_after="$(run_smoke)"
tickets_after="$(glpi_ticket_count)"
errors_after="$(demo_producer_errors)"

# Galera back to 3 is the real proof the return worked: a member that failed to
# rejoin sits at size 2 and nothing else shows it.
galera_after="?"
if [[ -n "$galera_cid" ]]; then
  galera_cid="$(docker ps -q --filter 'label=com.docker.swarm.service.name=data_galera-1' | head -1)"
  # shellcheck disable=SC2016
  galera_after="$(docker exec "$galera_cid" sh -c \
    'mariadb -u root -p"$(cat /run/secrets/dw_mariadb_root_password)" -N -B \
       -e "SHOW STATUS LIKE '"'"'wsrep_cluster_size'"'"';"' 2>/dev/null | awk '{print $2}')"
fi

# =============================================================================
verdict="✅"
notes=""
[[ "$smoke_drained" == "vert" ]] || { verdict="❌"; notes+="smoke ROUGE pendant le drain; "; }
[[ "$smoke_after"   == "vert" ]] || { verdict="❌"; notes+="smoke ROUGE après retour; "; }
[[ "${galera_size:-0}" == "2" ]] || { verdict="⚠️"; notes+="Galera size ${galera_size} (attendu 2); "; }
[[ "${galera_after:-0}" == "3" ]] || { verdict="❌"; notes+="Galera size ${galera_after} après retour (attendu 3); "; }
[[ "${cass_un:-0}" == "2" ]]     || { verdict="⚠️"; notes+="Cassandra ${cass_un} UN (attendu 2); "; }
# `red` is the failure that matters: yellow with a node missing is nominal —
# the replicas of the departed node are simply unassigned.
[[ "$es_health" == "red" ]]      && { verdict="❌"; notes+="Elasticsearch RED pendant le drain; "; }
[[ "$errors_after" == "n/a" || "$errors_after" == "$errors_drained" ]] \
  || { verdict="⚠️"; notes+="demo-producer: erreurs pendant le drain; "; }

chaos_report_row \
  "Drain planifié — \`${NODE}\`" \
  "drain-node.sh ${NODE}" \
  "reschedule, quorum conservé, ES yellow, retour sans SST" \
  "Galera ${galera_size}→${galera_after}, Cassandra ${cass_un} UN, ES ${es_health}, smoke ${smoke_drained}/${smoke_after}${notes:+, ${notes%; }}" \
  "${downtime} s" \
  "$([[ "$tickets_after" != "$tickets_before" ]] && echo "oui (${tickets_before}→${tickets_after})" || echo "non")" \
  "$verdict"

section "Result"
if [[ "$verdict" == "❌" ]]; then
  error "${NODE}: ${notes%; }"
  exit 1
fi
ok "${NODE}: drain and return nominal (${downtime}s unavailability)"

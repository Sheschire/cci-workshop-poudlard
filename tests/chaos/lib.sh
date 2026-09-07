#!/usr/bin/env bash
# =============================================================================
# Shared helpers for the chaos campaign (CDC §8.2).
#
# Sourced by tests/chaos/*.sh. What every scenario needs and none should
# re-implement:
#
#   measure_downtime   the actual number the CDC asks for — seconds of
#                      unavailability through the VIP, measured, not estimated
#   wait_converged     wait for the platform to be nominal again before the
#                      next scenario, so scenario N+1 does not measure the
#                      after-effects of scenario N
#   glpi_ticket_count  the alert → ticket loop, observed end to end
#   chaos_report_row   one row of the table docs/06-haute-disponibilite.md wants
# =============================================================================

[[ -n "${DW_CHAOS_LIB:-}" ]] && return 0
readonly DW_CHAOS_LIB=1

readonly CHAOS_CA="${DW_CERTS_DIR}/ca.crt"
readonly CHAOS_PROBE_HOST="whoami"

# -----------------------------------------------------------------------------
# vip_up — one probe through the VIP. Returns 0 if the platform serves.
#
# whoami and not GLPI: it is stateless, has no database behind it and answers in
# milliseconds. What is being measured is the availability of the ENTRY POINT
# (Keepalived + Traefik), and a slow application would pollute the measurement
# with its own latency.
# -----------------------------------------------------------------------------
vip_up() {
  curl -s --max-time 1 -o /dev/null \
       --noproxy '*' \
       --cacert "$CHAOS_CA" \
       --resolve "${CHAOS_PROBE_HOST}.${DOMAIN}:443:${VIP}" \
       "https://${CHAOS_PROBE_HOST}.${DOMAIN}/" 2>/dev/null
}

# -----------------------------------------------------------------------------
# measure_downtime <command…> — run the command, and report how many seconds
# the platform was unavailable while it ran and settled.
#
# The probe runs in the background at 5 Hz. Sampling matters: at 1 Hz a 4.6 s
# failover and a 5.4 s one are indistinguishable, and the CDC's promise is
# "< 5 s". 0.2 s gives the measurement a resolution of one fifth of a second,
# which is enough to state the result honestly.
#
# Prints the measured downtime in seconds (one decimal) on stdout.
# -----------------------------------------------------------------------------
measure_downtime() {
  local probe_file
  probe_file="$(mktemp)"

  ( while :; do
      if vip_up; then printf '1' >> "$probe_file"; else printf '0' >> "$probe_file"; fi
      sleep 0.2
    done ) &
  local probe_pid=$!
  # Stop the probe whatever happens to the scenario, including a Ctrl-C.
  # shellcheck disable=SC2064  # $probe_pid must be expanded NOW, not at signal time
  trap "kill ${probe_pid} 2>/dev/null || true" EXIT INT TERM

  "$@" >&2 || true

  # Let the platform settle before stopping the probe: the failure is only half
  # the story, the recovery is the other half and it is what the RTO measures.
  sleep "${CHAOS_SETTLE:-20}"

  kill "$probe_pid" 2>/dev/null || true
  wait "$probe_pid" 2>/dev/null || true
  trap - EXIT INT TERM

  # The LONGEST consecutive run of failures, not their total: two separate
  # one-second blips are not a five-second outage, and reporting them as one
  # would be a lie in the safe direction — which is still a lie.
  local samples longest
  samples="$(cat "$probe_file")"
  rm -f "$probe_file"
  longest="$(tr -d '1' <<<"${samples//1/ }" | tr ' ' '\n' | awk '{ if (length($0) > m) m = length($0) } END { print m+0 }')"
  awk -v n="$longest" 'BEGIN { printf "%.1f", n * 0.2 }'
}

# -----------------------------------------------------------------------------
# wait_converged [TIMEOUT] — wait until the platform is nominal again.
#
# "Nominal" is deliberately strict: every Swarm node Ready, every service at
# its desired replica count, and the VIP serving. Starting the next scenario on
# a half-converged cluster produces measurements that describe the previous
# scenario.
# -----------------------------------------------------------------------------
wait_converged() {
  local timeout=${1:-300} elapsed=0
  info "waiting for the platform to converge (max ${timeout}s)…"
  while (( elapsed < timeout )); do
    local nodes_ready degraded
    nodes_ready="$(docker node ls --format '{{.Status}}' 2>/dev/null | grep -c '^Ready$' || true)"
    # A service is degraded when running < desired. Jobs sit at 0/0 by design
    # and are excluded, or the platform would never look converged.
    degraded="$(docker service ls --format '{{.Replicas}}' 2>/dev/null \
                | awk -F/ '$1 != $2 && $2 != 0 { n++ } END { print n+0 }')"
    if [[ "${nodes_ready:-0}" == "3" && "${degraded:-1}" == "0" ]] && vip_up; then
      ok "converged after ${elapsed}s"
      return 0
    fi
    sleep 5
    elapsed=$(( elapsed + 5 ))
  done
  warn "not fully converged after ${timeout}s (nodes Ready=${nodes_ready:-?}, services dégradés=${degraded:-?})"
  return 1
}

# -----------------------------------------------------------------------------
# glpi_ticket_count — how many tickets GLPI holds right now.
#
# The chaos scenarios compare this before and after: CDC §8.2 asks for proof
# that a node loss OPENS A TICKET, which is the end of the alert chain
# (Prometheus → Alertmanager → alert2glpi → GLPI). Counting is the only way to
# observe it without a human looking at a screen.
# -----------------------------------------------------------------------------
glpi_ticket_count() {
  local cid
  cid="$(docker ps -q --filter 'label=com.docker.swarm.service.name=data_galera-1' | head -1)"
  [[ -n "$cid" ]] || { echo "?"; return 0; }
  # Read from the database rather than the REST API: no token to manage, and it
  # counts what GLPI actually stored rather than what a search returns.
  # shellcheck disable=SC2016  # $(cat …) must expand INSIDE the container
  docker exec "$cid" sh -c \
    'mariadb -u root -p"$(cat /run/secrets/dw_mariadb_root_password)" -N -B \
       -e "SELECT COUNT(*) FROM glpi.glpi_tickets WHERE is_deleted = 0;"' 2>/dev/null \
    || echo "?"
}

# -----------------------------------------------------------------------------
# demo_producer_errors — the error counter of the background load (CDC §7.8).
#
# The load generator writes to Cassandra at LOCAL_QUORUM and bulk-indexes into
# Elasticsearch throughout the campaign. Its error counter is the sharpest
# statement the platform can make: "production did not stop while a node was
# being killed". A non-zero counter is a failed HA claim, whatever the smoke
# test says.
# -----------------------------------------------------------------------------
demo_producer_errors() {
  local cid
  cid="$(docker ps -q --filter 'label=com.docker.swarm.service.name=demo_demo-producer' | head -1)"
  [[ -n "$cid" ]] || { echo "n/a"; return 0; }
  docker exec "$cid" sh -c 'wget -q -O - http://localhost:8000/metrics 2>/dev/null' \
    | awk '/^demo_producer_errors_total/ { s += $2 } END { printf "%d", s+0 }' \
    || echo "?"
}

# -----------------------------------------------------------------------------
# chaos_report_row — one row of the table CDC §8.2 requires.
# -----------------------------------------------------------------------------
chaos_report_row() {
  local scenario=$1 command=$2 expected=$3 observed=$4 downtime=$5 tickets=$6 verdict=$7
  report "| ${scenario} | \`${command}\` | ${expected} | ${observed} | ${downtime} | ${tickets} | ${verdict} |"
}

chaos_report_header() {
  report '| Scénario | Commande | Comportement attendu | Observé | Indispo. mesurée | Ticket GLPI | Résultat |'
  report '|---|---|---|---|---|---|---|'
}

# -----------------------------------------------------------------------------
# run_smoke — the smoke test, quietly, as a pass/fail gate between scenarios.
# -----------------------------------------------------------------------------
run_smoke() {
  if "${DW_ROOT}/tests/smoke/smoke.sh" --no-backup >/dev/null 2>&1; then
    echo "vert"
  else
    echo "ROUGE"
  fi
}

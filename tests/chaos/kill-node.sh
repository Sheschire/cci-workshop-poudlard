#!/usr/bin/env bash
# =============================================================================
# kill-node.sh — brutal loss of a node (CDC §8.2, n°3 et n°4).
#
#   tests/chaos/kill-node.sh <node> [--hold SECONDS] [--no-restore]
#
#   <node>         node1, node2 or node3 (Vagrant VM name = Swarm hostname)
#   --hold N       stay down for N seconds (default 120)
#   --no-restore   leave the node down (to inspect a degraded platform)
#
# `vagrant halt -f` is the power cut: no SIGTERM, no clean shutdown, no warning
# to Swarm. It is the only scenario that measures what the CDC actually
# promises — a VIP failover in under 5 seconds — and the only one that
# exercises the whole alert chain through to a GLPI ticket.
#
# node1 is a special case (CDC §8.2 n°4): it holds the NFS export for the GLPI
# files, the assumed SPOF of ADR-0006. Killing it must show GLPI still serving
# pages while attachments fail — degraded, not down — and the script says so
# explicitly rather than letting a green smoke test hide it.
#
# WHERE THIS RUNS is not the same as the other scenarios. `vagrant halt` needs
# Vagrant, so this runs on the WORKSTATION, which has no Docker cluster of its
# own. Every cluster interrogation therefore goes through `vagrant ssh` on a
# surviving node, and the smoke gate uses `--quick` (HTTP through the VIP,
# which is exactly what a workstation can observe and what matters here).
# =============================================================================
set -Eeuo pipefail
# Paths are relative to --source-path=scripts (see the lint-shell target).
# shellcheck source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh"
# shellcheck source=../tests/chaos/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

load_env
cd "$DW_ROOT"

NODE="${1:?usage: kill-node.sh <node> [--hold SECONDS] [--no-restore]}"
shift
HOLD=120
RESTORE=1
while (( $# )); do
  case "$1" in
    --hold)       HOLD="${2:?--hold needs a duration}"; shift 2 ;;
    --no-restore) RESTORE=0; shift ;;
    *)            die "unknown option: $1" ;;
  esac
done

need_cmd vagrant

# A surviving node, chosen before the kill, from which the Swarm is questioned.
SURVIVOR="node2"
[[ "$NODE" == "node2" ]] && SURVIVOR="node1"

# -----------------------------------------------------------------------------
# sdocker <docker args…> — run a Docker command on the surviving node.
#
# `vagrant ssh -c` gives the command to a login shell, so the whole thing is
# passed as ONE argument, already quoted by the caller. `tr -d '\r'` strips the
# carriage returns the pty adds, which would otherwise break every comparison
# against a numeric value.
# -----------------------------------------------------------------------------
sdocker() {
  vagrant ssh "$SURVIVOR" -c "sudo docker $1" 2>/dev/null | tr -d '\r'
}

# The ticket count, read from the Galera member on the survivor. Same query as
# chaos/lib.sh, but reached over SSH — see the note above about where this runs.
remote_ticket_count() {
  local cid
  cid="$(sdocker "ps -q --filter label=com.docker.swarm.service.name=data_galera-1 | head -1")"
  [[ -n "$cid" ]] || { printf '?'; return 0; }
  sdocker "exec ${cid} sh -c 'mariadb -u root -p\"\$(cat /run/secrets/dw_mariadb_root_password)\" -N -B -e \"SELECT COUNT(*) FROM glpi.glpi_tickets WHERE is_deleted = 0;\"'" \
    | tr -d '[:space:]' || printf '?'
}

# HTTP-only smoke: the workstation has no Docker socket, and what this scenario
# is about is whether the platform still SERVES.
quick_smoke() {
  if "${DW_ROOT}/tests/smoke/smoke.sh" --quick >/dev/null 2>&1; then
    printf 'vert'
  else
    printf 'ROUGE'
  fi
}

# Convergence, over SSH: every node Ready and no service short of its replicas.
remote_wait_converged() {
  local timeout=${1:-600} elapsed=0 ready degraded
  info "waiting for convergence (max ${timeout}s)…"
  while (( elapsed < timeout )); do
    ready="$(sdocker "node ls --format '{{.Status}}'" | grep -c '^Ready$' || true)"
    degraded="$(sdocker "service ls --format '{{.Replicas}}'" \
                | awk -F/ '$1 != $2 && $2 != 0 { n++ } END { print n+0 }')"
    if [[ "${ready:-0}" == "3" && "${degraded:-1}" == "0" ]] && vip_up; then
      ok "converged after ${elapsed}s"
      return 0
    fi
    sleep 10
    elapsed=$(( elapsed + 10 ))
  done
  warn "not fully converged after ${timeout}s (Ready=${ready:-?}, dégradés=${degraded:-?})"
  return 1
}

if [[ -z "${DW_REPORT:-}" ]]; then
  report_init "chaos-kill-node" "Chaos — perte brutale de \`${NODE}\`"
  chaos_report_header
fi

section "Scenario: vagrant halt -f ${NODE} (${HOLD}s)"
tickets_before="$(remote_ticket_count)"
info "before: ${tickets_before} ticket(s)"

# The node comes back whatever happens: an interrupted chaos test must not
# leave a two-node cluster overnight.
restore_node() {
  local rc=$?
  if (( RESTORE )); then
    section "Restarting ${NODE}"
    vagrant up "$NODE" >&2 || error "COULD NOT restart ${NODE} — run: vagrant up ${NODE}"
  fi
  exit "$rc"
}
trap restore_node EXIT

do_kill() {
  info "vagrant halt -f ${NODE}"
  vagrant halt -f "$NODE" >&2
  ok "${NODE} down"
  sleep "$HOLD"
}

# =============================================================================
# 1. The measurement the CDC asks for
# =============================================================================
downtime="$(CHAOS_SETTLE=15 measure_downtime do_kill)"
info "measured VIP unavailability: ${downtime}s (CDC §8.1: < 5 s)"

# =============================================================================
# 2. The platform, seen from a survivor, while the node is down
# =============================================================================
section "Platform state with ${NODE} down"

nodes_down="$(sdocker "node ls --format '{{.Status}}'" | grep -c 'Down' || true)"
log "Swarm: ${nodes_down:-0} node(s) Down"

vip_holder="inconnu"
for n in node1 node2 node3; do
  [[ "$n" == "$NODE" ]] && continue
  if vagrant ssh "$n" -c "ip -4 -brief addr show | grep -q ${VIP}" >/dev/null 2>&1; then
    vip_holder="$n"
    break
  fi
done
log "VIP ${VIP} portée par : ${vip_holder}"

smoke_down="$(quick_smoke)"
log "smoke (HTTP) avec ${NODE} éteint : ${smoke_down}"

# --- node1: the NFS SPOF (CDC §8.2 n°4) --------------------------------------
# GLPI must keep serving pages: the database is replicated and the web replica
# on a survivor is enough. What must NOT work is anything touching an
# attachment — and the 'soft' NFS mount is what turns that from "the process
# hangs forever in uninterruptible sleep" into "the I/O fails in ~15 s".
nfs_note="—"
if [[ "$NODE" == "node1" ]]; then
  section "Degraded behaviour: NFS SPOF (ADR-0006)"
  glpi_code="$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' \
                 --noproxy '*' \
                 --cacert "${DW_CERTS_DIR}/ca.crt" \
                 --resolve "glpi.${DOMAIN}:443:${VIP}" \
                 "https://glpi.${DOMAIN}/status.php" 2>/dev/null || echo "000")"
  if [[ "$glpi_code" == "200" ]]; then
    ok "GLPI sert toujours (HTTP 200) — dégradé sur les pièces jointes uniquement"
    nfs_note="GLPI 200, pièces jointes indisponibles (RTO bascule NFS : 30 min, cf. PRA)"
  else
    warn "GLPI répond ${glpi_code} — le montage NFS n'a pas borné l'échec comme prévu"
    nfs_note="GLPI ${glpi_code} — À INVESTIGUER : options soft/timeo/retrans (ADR-0006)"
  fi
fi

# =============================================================================
# 3. The alert chain: a lost node must OPEN A TICKET
#
# The criterion of CDC §8.2 n°3, and the end of the chain built in phase 4:
# NodeDown fires (for: 2m) → Alertmanager groups and inhibits → the alert2glpi
# webhook creates the ticket. Waiting is unavoidable: the `for:` clause exists
# precisely so a 30-second blip does not open a ticket at 3 a.m.
# =============================================================================
section "Alert chain (NodeDown → GLPI ticket)"
alert_seen="non"
elapsed=0
while (( elapsed < 240 )); do
  am_cid="$(sdocker "ps -q --filter label=com.docker.swarm.service.name=monitoring_alertmanager | head -1")"
  if [[ -n "$am_cid" ]] \
     && sdocker "exec ${am_cid} wget -q -O - http://localhost:9093/api/v2/alerts" | grep -q 'NodeDown'; then
    alert_seen="oui (après ${elapsed}s)"
    ok "NodeDown active dans Alertmanager après ${elapsed}s"
    break
  fi
  sleep 15
  elapsed=$(( elapsed + 15 ))
done
[[ "$alert_seen" == "non" ]] && warn "NodeDown non observée en 240 s"

# =============================================================================
# 4. Return to service
# =============================================================================
if (( RESTORE )); then
  section "Restarting ${NODE}"
  vagrant up "$NODE" >&2
  trap - EXIT
  ok "${NODE} back"
  # Longer than a drain: the datastores must rejoin (Galera IST or SST,
  # Cassandra gossip, Elasticsearch shard reallocation).
  remote_wait_converged 600 || true
fi

smoke_after="$(quick_smoke)"
tickets_after="$(remote_ticket_count)"

# =============================================================================
verdict="✅"
notes=""
awk -v d="$downtime" 'BEGIN { exit (d > 5.0) ? 0 : 1 }' \
  && { verdict="❌"; notes+="bascule VIP ${downtime}s > 5 s (CDC §8.1); "; }
[[ "$smoke_down" == "vert" ]] || { verdict="❌"; notes+="smoke ROUGE nœud éteint; "; }
if (( RESTORE )); then
  [[ "$smoke_after" == "vert" ]] || { verdict="❌"; notes+="smoke ROUGE après retour; "; }
fi
[[ "$alert_seen" == "non" ]] && { verdict="⚠️"; notes+="NodeDown non observée en 240 s; "; }

scenario_label="Perte brutale — \`${NODE}\`"
[[ "$NODE" == "node1" ]] && scenario_label+=" (porteur NFS)"

chaos_report_row \
  "$scenario_label" \
  "kill-node.sh ${NODE}" \
  "bascule VIP < 5 s, plateforme servie, ticket NodeDown créé" \
  "VIP → ${vip_holder}, smoke ${smoke_down}/${smoke_after}, NFS : ${nfs_note}${notes:+, ${notes%; }}" \
  "${downtime} s" \
  "${alert_seen}$([[ "$tickets_after" != "$tickets_before" ]] && echo " — tickets ${tickets_before}→${tickets_after}" || echo "")" \
  "$verdict"

section "Result"
if [[ "$verdict" == "❌" ]]; then
  error "${NODE}: ${notes%; }"
  exit 1
fi
ok "${NODE}: bascule VIP ${downtime}s, smoke ${smoke_after}"

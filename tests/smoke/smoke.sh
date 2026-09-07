#!/usr/bin/env bash
# =============================================================================
# `make smoke` — end-to-end validation of the platform (CDC §8.2).
#
#   tests/smoke/smoke.sh [--quick] [--no-backup]
#
#   --quick       HTTP checks only (no cluster interrogation) — for a fast loop
#   --no-backup   skip the backup freshness check (before the first run)
#
# What "smoke" means here
# -----------------------
# Not "the services are running" — `docker service ls` already says that, and it
# says it about a GLPI that returns 500 on every page. This walks the platform
# the way a user and an operator would:
#
#   1. through the VIP, over HTTPS, with the internal CA — so it exercises
#      Keepalived, Traefik, the certificate, the routers and the middlewares;
#   2. the admin URLs must be PROTECTED, not merely reachable: a 200 without
#      credentials on Prometheus is a failure, not a success;
#   3. the datastores must be in their nominal cluster state, not just up;
#   4. Prometheus must see all its targets and hold no firing critical alert;
#   5. the backups must be fresher than the RPO.
#
# Run from a manager node. Produces a Markdown report under reports/.
# =============================================================================
set -Eeuo pipefail
# Paths are relative to --source-path=scripts (see the lint-shell target).
# shellcheck source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh"

load_env
cd "$DW_ROOT"

QUICK=0
CHECK_BACKUP=1
while (( $# )); do
  case "$1" in
    --quick)     QUICK=1; shift ;;
    --no-backup) CHECK_BACKUP=0; shift ;;
    -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown option: $1" ;;
  esac
done

readonly CA="${DW_CERTS_DIR}/ca.crt"
[[ -r "$CA" ]] || die "${CA} not found — run 'make certs' first"

ADMIN_PW=""
[[ -r "${DW_SECRETS_DIR}/dw_traefik_admin_password.txt" ]] \
  && ADMIN_PW="$(cat "${DW_SECRETS_DIR}/dw_traefik_admin_password.txt")"

report_init smoke "Test de bout en bout — \`make smoke\`"
report '| # | Vérification | Attendu | Observé | Résultat |'
report '|---|---|---|---|---|'

N=0
PASS=0
FAIL=0

# -----------------------------------------------------------------------------
# check LABEL EXPECTED ACTUAL — record one line of the report.
# -----------------------------------------------------------------------------
smoke_check() {
  local label=$1 expected=$2 actual=$3
  N=$(( N + 1 ))
  if [[ "$actual" == "$expected" ]]; then
    ok "${label}: ${actual}"
    report "| ${N} | ${label} | \`${expected}\` | \`${actual}\` | ✅ |"
    PASS=$(( PASS + 1 ))
    return 0
  fi
  error "${label}: expected ${expected}, got ${actual}"
  report "| ${N} | ${label} | \`${expected}\` | \`${actual}\` | ❌ |"
  FAIL=$(( FAIL + 1 ))
  # Always 0: the script runs under `set -e`, and a check that returned
  # non-zero would abort the run on the FIRST failure. A smoke test that stops
  # at the first problem tells you about one problem; this one tells you about
  # all of them, and the exit code at the end is what fails the build.
  return 0
}

# Same, when the expectation is "at least N" rather than an exact value.
smoke_check_min() {
  local label=$1 minimum=$2 actual=$3
  N=$(( N + 1 ))
  if [[ "${actual:-0}" =~ ^[0-9]+$ ]] && (( actual >= minimum )); then
    ok "${label}: ${actual} (≥ ${minimum})"
    report "| ${N} | ${label} | \`≥ ${minimum}\` | \`${actual}\` | ✅ |"
    PASS=$(( PASS + 1 ))
    return 0
  fi
  error "${label}: expected at least ${minimum}, got ${actual:-none}"
  report "| ${N} | ${label} | \`≥ ${minimum}\` | \`${actual:-—}\` | ❌ |"
  FAIL=$(( FAIL + 1 ))
  return 0   # see smoke_check
}

# -----------------------------------------------------------------------------
# All HTTP goes through the VIP, resolved with --resolve rather than /etc/hosts.
#
# `--resolve <host>:443:<VIP>` sends the request to the VIP while presenting the
# real SNI and Host header. That is what makes this a test of the VIP: with a
# hosts entry, a stale DNS cache or a local override would silently point the
# test somewhere else and it would still pass.
# -----------------------------------------------------------------------------
vip_curl() {
  local host=$1 path=${2:-/}; shift 2 || true
  curl -sS --max-time 15 \
       --cacert "$CA" \
       --resolve "${host}:443:${VIP}" \
       "$@" \
       "https://${host}${path}"
}
vip_code() {
  local host=$1 path=${2:-/}; shift 2 || true
  curl -s --max-time 15 -o /dev/null -w '%{http_code}' \
       --cacert "$CA" \
       --resolve "${host}:443:${VIP}" \
       "$@" \
       "https://${host}${path}" 2>/dev/null || echo "000"
}

# =============================================================================
# 1. The entry point
# =============================================================================
section "1. Entry point (VIP ${VIP})"

# The VIP answers at all. Everything else depends on this, so it is checked
# first and separately: a failure here means Keepalived, not the applications.
smoke_check "VIP joignable (ICMP)" "ok" \
  "$(ping -c 2 -W 2 "$VIP" >/dev/null 2>&1 && echo ok || echo ko)"

# The certificate is the internal CA's, and it is valid for the name asked.
# `Verify return code: 0` is the only acceptable answer: a self-signed
# certificate served by mistake would still terminate TLS and serve pages.
tls_verify="$(openssl s_client -connect "${VIP}:443" -servername "whoami.${DOMAIN}" \
                -CAfile "$CA" </dev/null 2>/dev/null \
              | grep -oE 'Verify return code: [0-9]+' | head -1 | grep -oE '[0-9]+$')"
smoke_check "Certificat validé par la CA interne" "0" "${tls_verify:-none}"

# HTTP must redirect, never serve. A 200 on port 80 means the redirection
# middleware is gone and credentials could travel in clear.
http_code="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' \
              --resolve "whoami.${DOMAIN}:80:${VIP}" \
              "http://whoami.${DOMAIN}/" 2>/dev/null || echo "000")"
smoke_check "HTTP → HTTPS (redirection permanente)" "308" "$http_code"

# =============================================================================
# 2. Public services
# =============================================================================
section "2. Public services"

smoke_check "whoami répond via la VIP" "200" "$(vip_code "whoami.${DOMAIN}")"

# The real client IP must reach the application. This is the whole point of
# Traefik in host mode (ADR-0003): with the Swarm routing mesh, RemoteAddr
# would be a 10.20.x.x gateway and CrowdSec would ban the mesh instead of the
# attacker.
whoami_body="$(vip_curl "whoami.${DOMAIN}" / 2>/dev/null || true)"
remote_addr="$(grep -i '^RemoteAddr:' <<<"$whoami_body" | awk '{print $2}' | cut -d: -f1)"
if [[ "$remote_addr" =~ ^10\.20\. ]]; then
  smoke_check "IP client réelle préservée (mode host)" "non-10.20.x" "$remote_addr"
else
  smoke_check "IP client réelle préservée (mode host)" "non-10.20.x" "non-10.20.x"
  log "   RemoteAddr observé : ${remote_addr:-?}"
fi

# GLPI: 200 AND the database behind it. status.php answers 200 from Apache
# alone if the application is broken, so the body is what is checked.
glpi_status="$(vip_curl "glpi.${DOMAIN}" /status.php 2>/dev/null | tr -d '[:space:]' || true)"
smoke_check "GLPI opérationnel (status.php)" "GLPI_OK" \
  "$(grep -q 'GLPI_OK' <<<"$glpi_status" && echo GLPI_OK || echo "${glpi_status:0:20}")"

# =============================================================================
# 3. Admin services must be PROTECTED
#
# Reachability is not the test here. An administration UI that answers 200
# without credentials is a finding, not a success — so the expected result is
# 401 (or 403 from outside ADMIN_CIDR), and 200 without credentials FAILS.
# =============================================================================
section "3. Administration interfaces (must be protected)"

for host in traefik prometheus alertmanager grafana kibana minio; do
  code="$(vip_code "${host}.${DOMAIN}")"
  N=$(( N + 1 ))
  case "$code" in
    401|403)
      ok "${host}: ${code} (protégé)"
      report "| ${N} | \`${host}.${DOMAIN}\` protégé sans identifiants | \`401/403\` | \`${code}\` | ✅ |"
      PASS=$(( PASS + 1 ))
      ;;
    200)
      # Grafana is the one legitimate 200: it serves its own login page and
      # authenticates itself. Anything else answering 200 unauthenticated is a
      # missing middleware.
      if [[ "$host" == "grafana" ]]; then
        ok "${host}: 200 (page de connexion Grafana)"
        report "| ${N} | \`${host}.${DOMAIN}\` sert sa page de connexion | \`200\` | \`200\` | ✅ |"
        PASS=$(( PASS + 1 ))
      else
        error "${host}: 200 SANS identifiants — middleware d'authentification absent"
        report "| ${N} | \`${host}.${DOMAIN}\` protégé sans identifiants | \`401/403\` | \`200\` | ❌ |"
        FAIL=$(( FAIL + 1 ))
      fi
      ;;
    *)
      error "${host}: ${code}"
      report "| ${N} | \`${host}.${DOMAIN}\` joignable | \`401/403\` | \`${code}\` | ❌ |"
      FAIL=$(( FAIL + 1 ))
      ;;
  esac
done

# …and they must WORK with credentials. Protected-but-broken is still broken.
if [[ -n "$ADMIN_PW" ]]; then
  smoke_check "Prometheus authentifié" "200" \
    "$(vip_code "prometheus.${DOMAIN}" /-/healthy -u "admin:${ADMIN_PW}")"
  smoke_check "Alertmanager authentifié" "200" \
    "$(vip_code "alertmanager.${DOMAIN}" /-/healthy -u "admin:${ADMIN_PW}")"
else
  warn "secrets/dw_traefik_admin_password.txt absent — contrôles authentifiés ignorés"
fi

# =============================================================================
# 4. Cluster state
#
# Skipped by --quick: these need `docker exec` into the datastores, which is
# what makes a full run take a minute rather than a few seconds.
# =============================================================================
if (( QUICK == 0 )); then
section "4. Cluster state"

need_docker

# --- Swarm ---
node_ready="$(docker node ls --format '{{.Status}}' 2>/dev/null | grep -c '^Ready$' || true)"
smoke_check "Nœuds Swarm Ready" "3" "${node_ready:-0}"
managers="$(docker node ls --format '{{.ManagerStatus}}' 2>/dev/null | grep -cE 'Leader|Reachable' || true)"
smoke_check "Managers dans le quorum Raft" "3" "${managers:-0}"

# --- Galera ---
# `wsrep_cluster_size` and not "the port answers": a node performing an SST
# accepts connections and refuses every write.
galera_cid="$(docker ps -q --filter 'label=com.docker.swarm.service.name=data_galera-1' | head -1)"
if [[ -n "$galera_cid" ]]; then
  # shellcheck disable=SC2016  # $(cat …) must expand INSIDE the container
  gsize="$(docker exec "$galera_cid" sh -c \
    'mariadb -u root -p"$(cat /run/secrets/dw_mariadb_root_password)" -N -B \
       -e "SHOW STATUS LIKE '"'"'wsrep_cluster_size'"'"';"' 2>/dev/null | awk '{print $2}')"
  smoke_check "Galera wsrep_cluster_size" "3" "${gsize:-0}"
  # shellcheck disable=SC2016
  gstatus="$(docker exec "$galera_cid" sh -c \
    'mariadb -u root -p"$(cat /run/secrets/dw_mariadb_root_password)" -N -B \
       -e "SHOW STATUS LIKE '"'"'wsrep_cluster_status'"'"';"' 2>/dev/null | awk '{print $2}')"
  smoke_check "Galera wsrep_cluster_status" "Primary" "${gstatus:-unknown}"
else
  warn "aucune tâche data_galera-1 sur ce nœud — contrôles Galera ignorés"
fi

# --- Cassandra ---
cass_cid="$(docker ps -q --filter 'label=com.docker.swarm.service.name=data_cassandra-1' | head -1)"
if [[ -n "$cass_cid" ]]; then
  un="$(docker exec "$cass_cid" nodetool status 2>/dev/null | awk '$1 == "UN" {n++} END {print n+0}')"
  smoke_check "Cassandra nœuds UN" "3" "${un:-0}"
else
  warn "aucune tâche data_cassandra-1 sur ce nœud — contrôles Cassandra ignorés"
fi

# --- Elasticsearch ---
es_cid="$(docker ps -q --filter 'label=com.docker.swarm.service.name=data_es-1' | head -1)"
if [[ -n "$es_cid" ]]; then
  # shellcheck disable=SC2016
  health="$(docker exec "$es_cid" sh -c \
    'curl -s -u "elastic:$(cat /run/secrets/dw_es_elastic_password)" \
       localhost:9200/_cluster/health' 2>/dev/null | jq -r '.status // "unknown"')"
  smoke_check "Elasticsearch cluster health" "green" "${health:-unknown}"
  # shellcheck disable=SC2016
  nodes="$(docker exec "$es_cid" sh -c \
    'curl -s -u "elastic:$(cat /run/secrets/dw_es_elastic_password)" \
       localhost:9200/_cluster/health' 2>/dev/null | jq -r '.number_of_nodes // 0')"
  smoke_check "Elasticsearch nœuds" "3" "${nodes:-0}"
else
  warn "aucune tâche data_es-1 sur ce nœud — contrôles Elasticsearch ignorés"
fi

# =============================================================================
# 5. Supervision
# =============================================================================
section "5. Supervision"

prom_cid="$(docker ps -q --filter 'label=com.docker.swarm.service.name=monitoring_prometheus' | head -1)"
if [[ -n "$prom_cid" ]]; then
  prom_q() {
    docker exec "$prom_cid" wget -q -O - \
      "http://localhost:9090/api/v1/query?query=$1" 2>/dev/null
  }

  # Every target up. `up == 0` on a single exporter means a blind spot, and a
  # blind spot is where the next incident happens unseen.
  down="$(prom_q 'count(up==0)' | jq -r '.data.result[0].value[1] // "0"')"
  smoke_check "Cibles Prometheus injoignables" "0" "${down:-0}"

  # And enough targets to be plausible: `count(up==0) == 0` is also true when
  # Prometheus discovered nothing at all.
  total="$(prom_q 'count(up)' | jq -r '.data.result[0].value[1] // "0"')"
  smoke_check_min "Cibles Prometheus découvertes" 20 "${total:-0}"

  # No firing critical alert. Warnings are tolerated: they are what a platform
  # under load looks like. A critical is not.
  crit="$(prom_q 'count(ALERTS{alertstate="firing",severity="critical"})' \
          | jq -r '.data.result[0].value[1] // "0"')"
  smoke_check "Alertes critical actives" "0" "${crit:-0}"
  if [[ "${crit:-0}" != "0" ]]; then
    prom_q 'ALERTS{alertstate="firing",severity="critical"}' \
      | jq -r '.data.result[]?.metric.alertname' | sed 's/^/    /' >&2
  fi

  # --- Backups (CDC §9.1): fresher than the RPO ---------------------------
  if (( CHECK_BACKUP )); then
    stale="$(prom_q 'count((time()-backup_last_success_timestamp)>26*3600)' \
             | jq -r '.data.result[0].value[1] // "0"')"
    jobs="$(prom_q 'count(backup_last_success_timestamp)' \
            | jq -r '.data.result[0].value[1] // "0"')"
    if [[ "${jobs:-0}" == "0" ]]; then
      # Not a failure on a platform that has just been deployed — but said
      # out loud, because "no backup metric" and "backups are fine" must never
      # look the same in a report.
      warn "aucune métrique de sauvegarde : aucun job n'a encore tourné (make backup-now)"
      report "| — | Sauvegardes | métriques présentes | aucune | ⚠️ |"
    else
      smoke_check "Sauvegardes plus vieilles que le RPO (26 h)" "0" "${stale:-0}"
    fi
  fi
else
  warn "aucune tâche monitoring_prometheus sur ce nœud — contrôles de supervision ignorés"
fi
fi

# =============================================================================
section "Résumé"
report ''
if (( FAIL == 0 )); then
  ok "${PASS} vérifications OK, 0 échec"
  report "**Résultat : ${PASS} vérifications, 0 échec.**"
  info "rapport : ${DW_REPORT}"
  exit 0
fi
error "${FAIL} vérification(s) en échec sur $(( PASS + FAIL ))"
report "**Résultat : ${FAIL} échec(s) sur $(( PASS + FAIL )).**"
info "rapport : ${DW_REPORT}"
exit 1

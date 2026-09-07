#!/usr/bin/env bash
# =============================================================================
# network-isolation.sh — the segmentation is real, not just declared (CDC §6.5).
#
#   tests/smoke/network-isolation.sh
#
# Why this test exists
# --------------------
# `stacks/*.yml` says which service is attached to which overlay, and
# `validate-stacks.sh` checks that the files say what they should. Neither
# proves anything about the running cluster: an `external: true` network that
# was created without `internal`, a service attached to one overlay too many, a
# database port published by accident — all of these validate perfectly and
# leave the platform open.
#
# So this asks the running cluster, from the position of an attacker who has
# already obtained code execution in the DMZ:
#
#   1. a container on `edge` must NOT reach galera-1:3306, cassandra-1:9042,
#      es-1:9200 or minio:9000 — layer 4 of the firewall (CDC §6.1);
#   2. no database port may answer on any host IP — layer 1;
#   3. the internal overlays must really be `internal`, and `data` encrypted;
#   4. only the two socket proxies may see /var/run/docker.sock;
#   5. only swarm-cronjob may reach the write-capable proxy.
#
# Run from a manager node. Produces a Markdown report under reports/.
# =============================================================================
set -Eeuo pipefail
# Paths are relative to --source-path=scripts (see the lint-shell target).
# shellcheck source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh"

need_manager
load_env
cd "$DW_ROOT"

readonly PROBE_IMAGE="${REGISTRY}/dockerwarts/backup-runner:${IMAGE_TAG}"

report_init network-isolation "Isolation réseau — \`tests/smoke/network-isolation.sh\`"
report '| # | Contrôle | Attendu | Observé | Résultat |'
report '|---|---|---|---|---|'

N=0
PASS=0
FAIL=0
iso_check() {
  local label=$1 expected=$2 actual=$3
  N=$(( N + 1 ))
  if [[ "$actual" == "$expected" ]]; then
    ok "${label}"
    report "| ${N} | ${label} | \`${expected}\` | \`${actual}\` | ✅ |"
    PASS=$(( PASS + 1 ))
  else
    error "${label}: attendu ${expected}, obtenu ${actual}"
    report "| ${N} | ${label} | \`${expected}\` | \`${actual}\` | ❌ |"
    FAIL=$(( FAIL + 1 ))
  fi
  return 0   # never abort under set -e: every finding must be reported
}

# =============================================================================
# 1. From `edge`, the datastores must be unreachable
#
# The probe container is deliberately attached to `edge` ONLY. `edge` is the
# network Traefik, whoami and the GLPI front-end share — i.e. the one an
# attacker lands on after compromising a published service. It is the only
# non-internal overlay, and nothing on it has any business speaking SQL.
#
# `timeout 5` bounds each attempt: an overlay that DROPs (rather than rejects)
# would otherwise hang until the TCP stack gives up, and the test would look
# like a hang rather than a pass.
# =============================================================================
section "1. Depuis le réseau edge, les datastores doivent être injoignables"

probe_edge() {
  local target=$1 port=$2
  docker run --rm --network edge \
    --user 10002:10002 --cap-drop ALL --security-opt no-new-privileges:true \
    --entrypoint /bin/bash "$PROBE_IMAGE" \
    -c "timeout 5 bash -c 'echo > /dev/tcp/${target}/${port}' 2>/dev/null && echo REACHABLE || echo blocked" \
    2>/dev/null || echo blocked
}

for pair in "galera-1:3306" "cassandra-1:9042" "es-1:9200" "minio:9000" "db-proxy:3306"; do
  target="${pair%%:*}"
  port="${pair##*:}"
  iso_check "edge → ${target}:${port} bloqué" "blocked" "$(probe_edge "$target" "$port")"
done

# The counter-test matters as much as the tests: if the probe cannot reach
# ANYTHING, the five results above are meaningless — a broken probe passes
# every isolation check. Traefik is on `edge` and answers /ping.
iso_check "contre-test : la sonde atteint bien traefik:80 depuis edge" \
  "REACHABLE" "$(probe_edge traefik 80)"

# =============================================================================
# 2. No database port answers on a host IP
#
# Layer 1 of the firewall (CDC §6.1): DOCKER-USER and DW-INPUT. A `ports:`
# entry added by mistake to a stack would publish a database on every node —
# and Docker's own iptables rules bypass INPUT, which is exactly why
# DOCKER-USER exists and why this is checked from outside the containers.
# =============================================================================
section "2. Aucun port de base de données ne répond sur les IP des hôtes"

host_port_closed() {
  local host=$1 port=$2
  if timeout 3 bash -c "echo > /dev/tcp/${host}/${port}" 2>/dev/null; then
    echo OPEN
  else
    echo closed
  fi
}

# 3306 MariaDB · 4567/4568/4444 Galera (réplication, IST, SST) · 9042 Cassandra
# 7000/7001 gossip · 7199 JMX · 9200/9300 Elasticsearch · 5601 Kibana
# 9000/9001 MinIO · 9090 Prometheus · 3000 Grafana · 2375/2376 API Docker
readonly FORBIDDEN_PORTS=(3306 4567 4568 4444 9042 7000 7001 7199 9200 9300 5601 9000 9001 9090 3000 2375 2376)

for node_ip in "$NODE1_IP" "$NODE2_IP" "$NODE3_IP"; do
  open_ports=""
  for port in "${FORBIDDEN_PORTS[@]}"; do
    [[ "$(host_port_closed "$node_ip" "$port")" == "OPEN" ]] && open_ports+="${port} "
  done
  iso_check "aucun port de données ouvert sur ${node_ip}" "" "${open_ports% }"
done

# Counter-test again: 443 must be open on the VIP, or the loop above proves
# nothing but that the network is down.
iso_check "contre-test : 443 ouvert sur la VIP ${VIP}" "OPEN" "$(host_port_closed "$VIP" 443)"

# =============================================================================
# 3. The overlays are what they claim to be
# =============================================================================
section "3. Propriétés des réseaux overlay"

net_prop() {
  docker network inspect "$1" --format "$2" 2>/dev/null || echo "absent"
}

for net in data monitoring mgmt crowdsec; do
  iso_check "réseau ${net} est internal" "true" "$(net_prop "$net" '{{.Internal}}')"
done
# `edge` is the ONE overlay that must not be internal: it carries the traffic
# Traefik forwards, and an internal edge would have no route to anything.
iso_check "réseau edge n'est pas internal" "false" "$(net_prop edge '{{.Internal}}')"

# IPsec on `data` (ADR-0007): it is what makes plain HTTP acceptable between
# Elasticsearch nodes and between the jobs and MinIO.
encrypted="$(net_prop data '{{index .Options "encrypted"}}')"
if [[ "${DATA_NETWORK_ENCRYPTED:-true}" == "true" ]]; then
  iso_check "réseau data chiffré (IPsec)" "true" \
    "$([[ -n "$encrypted" && "$encrypted" != "<no value>" && "$encrypted" != "absent" ]] && echo true || echo false)"
else
  warn "DATA_NETWORK_ENCRYPTED=false dans .env : chiffrement du réseau data non contrôlé"
fi

# The private scheduler network (stacks/backup.yml).
iso_check "réseau backup_cronjob est internal" "true" "$(net_prop backup_cronjob '{{.Internal}}')"

# =============================================================================
# 4. The Docker socket
#
# CDC §6.4. Checked at RUNTIME, not in the stack files: a container started by
# hand, or a service updated with `docker service update --mount-add`, would
# never appear in a stack file.
# =============================================================================
section "4. Socket Docker"

offenders=""
while read -r cid name; do
  [[ -z "$cid" ]] && continue
  if docker inspect "$cid" --format '{{range .Mounts}}{{.Source}} {{end}}' 2>/dev/null \
     | grep -q '/var/run/docker.sock'; then
    case "$name" in
      *docker-socket-proxy*) ;;                      # the two documented exceptions
      *) offenders+="${name} " ;;
    esac
  fi
done < <(docker ps --format '{{.ID}} {{.Names}}')
iso_check "seuls les proxies montent /var/run/docker.sock" "" "${offenders% }"

# And the read-only proxy must really refuse writes. `POST /services/.../update`
# with no body returns 400 from a proxy that FORWARDS it, and 403 from one that
# blocks it — the difference between "configured read-only" and "read-only".
ro_proxy_cid="$(docker ps -q --filter 'label=com.docker.swarm.service.name=edge_docker-socket-proxy' | head -1)"
if [[ -n "$ro_proxy_cid" ]]; then
  code="$(docker run --rm --network mgmt \
            --user 10002:10002 --cap-drop ALL --security-opt no-new-privileges:true \
            --entrypoint /bin/bash "$PROBE_IMAGE" \
            -c 'curl -s -o /dev/null -w "%{http_code}" -X POST \
                  http://docker-socket-proxy:2375/services/create' 2>/dev/null || echo "000")"
  iso_check "le proxy en lecture seule refuse un POST" "403" "$code"
else
  warn "aucune tâche edge_docker-socket-proxy sur ce nœud — contrôle POST ignoré"
fi

# =============================================================================
# 5. The write-capable proxy is reachable by swarm-cronjob alone
# =============================================================================
section "5. Proxy Docker en écriture"

members="$(docker network inspect backup_cronjob \
             --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || echo "absent")"
unexpected=""
for m in $members; do
  case "$m" in
    *swarm-cronjob*|*docker-socket-proxy-rw*) ;;
    *) unexpected+="${m} " ;;
  esac
done
iso_check "aucun membre inattendu sur backup_cronjob" "" "${unexpected% }"

# From `mgmt` — where Prometheus and Traefik live — the write proxy must be
# unreachable. This is the check that would catch someone "temporarily"
# attaching it to a shared network.
from_mgmt="$(docker run --rm --network mgmt \
  --user 10002:10002 --cap-drop ALL --security-opt no-new-privileges:true \
  --entrypoint /bin/bash "$PROBE_IMAGE" \
  -c "timeout 5 bash -c 'echo > /dev/tcp/docker-socket-proxy-rw/2375' 2>/dev/null && echo REACHABLE || echo blocked" \
  2>/dev/null || echo blocked)"
iso_check "mgmt → docker-socket-proxy-rw bloqué" "blocked" "$from_mgmt"

# =============================================================================
section "Résumé"
report ''
if (( FAIL == 0 )); then
  ok "${PASS} contrôles d'isolation OK, 0 échec"
  report "**Résultat : ${PASS} contrôles, 0 échec.**"
  info "rapport : ${DW_REPORT}"
  exit 0
fi
error "${FAIL} contrôle(s) d'isolation en échec sur $(( PASS + FAIL ))"
report "**Résultat : ${FAIL} échec(s) sur $(( PASS + FAIL )).**"
info "rapport : ${DW_REPORT}"
exit 1

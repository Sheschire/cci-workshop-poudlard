#!/usr/bin/env bash
# =============================================================================
# `make status` — one screen showing the state of the whole platform.
#
# Read-only: safe to run at any time, including in the middle of a chaos test.
# Every section degrades gracefully when the corresponding stack is not
# deployed yet (phase 0 to 5 all use this command).
# =============================================================================
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

need_manager
load_env

section "Swarm nodes"
docker node ls

section "Services"
docker service ls --format 'table {{.Name}}\t{{.Mode}}\t{{.Replicas}}\t{{.Image}}' \
  | sed 's/@sha256:[0-9a-f]\{12\}[0-9a-f]*//'

section "Tasks not running"
if docker service ps --filter 'desired-state=running' \
     --format '{{.Name}}\t{{.CurrentState}}\t{{.Error}}' \
     "$(docker service ls -q)" 2>/dev/null | grep -v 'Running' | grep -q .; then
  docker service ps --filter 'desired-state=running' \
    --format 'table {{.Name}}\t{{.Node}}\t{{.CurrentState}}\t{{.Error}}' \
    "$(docker service ls -q)" | grep -v ' Running ' || true
else
  ok "every task is Running"
fi

section "Entry point"
if ping -c 1 -W 2 "$VIP" >/dev/null 2>&1; then
  ok "VIP ${VIP} answers to ping"
else
  error "VIP ${VIP} is unreachable"
fi
if curl -sf --max-time 3 -o /dev/null "http://127.0.0.1/ping"; then
  ok "local Traefik: /ping OK (this node can hold the VIP)"
else
  warn "local Traefik: /ping KO (this node gives the VIP away)"
fi
if ip -4 -brief addr show | grep -F "$VIP" >/dev/null 2>&1; then
  ok "the VIP is currently carried by $(hostname)"
else
  log "the VIP is carried by another node"
fi

# --- Stateful clusters -------------------------------------------------------
# Each block is best-effort: a missing service is reported, never fatal.
section "MariaDB Galera"
if docker service ls --format '{{.Name}}' | grep -q '^data_galera-1$'; then
  # shellcheck disable=SC2016  # expanded inside the container, not here
  svc_exec data_galera-1 sh -c \
    'mariadb -u root -p"$(cat /run/secrets/dw_mariadb_root_password)" -N -B -e "
       SHOW STATUS WHERE Variable_name IN
         (\"wsrep_cluster_size\",\"wsrep_cluster_status\",\"wsrep_local_state_comment\",\"wsrep_ready\");"' \
    2>/dev/null || warn "galera-1 did not answer (is it on this node?)"
else
  log "the data stack is not deployed"
fi

section "Cassandra"
if docker service ls --format '{{.Name}}' | grep -q '^data_cassandra-1$'; then
  svc_exec data_cassandra-1 nodetool status 2>/dev/null | sed -n '5,20p' \
    || warn "cassandra-1 did not answer (is it on this node?)"
else
  log "the data stack is not deployed"
fi

section "Elasticsearch"
if docker service ls --format '{{.Name}}' | grep -q '^data_es-1$'; then
  # shellcheck disable=SC2016  # expanded inside the container, not here
  svc_exec data_es-1 sh -c \
    'curl -s -u "elastic:$(cat /run/secrets/dw_es_elastic_password)" \
       "http://localhost:9200/_cluster/health?pretty"' 2>/dev/null \
    | jq -r '"status=\(.status) nodes=\(.number_of_nodes) shards=\(.active_shards) unassigned=\(.unassigned_shards)"' \
    || warn "es-1 did not answer (is it on this node?)"
else
  log "the data stack is not deployed"
fi

section "Alerts currently firing"
if docker service ls --format '{{.Name}}' | grep -q '^monitoring_prometheus$'; then
  curl -s --max-time 5 "http://127.0.0.1:9090/api/v1/alerts" 2>/dev/null \
    | jq -r '.data.alerts[]? | "\(.labels.severity)\t\(.labels.alertname)\t\(.labels.instance // .labels.node // "-")"' \
    | sort | column -t 2>/dev/null || log "Prometheus is not reachable from this node"
else
  log "the monitoring stack is not deployed"
fi

section "Backups"
if docker service ls --format '{{.Name}}' | grep -q '^backup_backup-metrics$'; then
  awk '/^backup_last_success_timestamp/ {
         split($0, a, /[{}]/); split(a[2], b, /"/);
         age = (systime() - $NF) / 3600;
         printf "  %-24s %6.1f h ago\n", b[2], age
       }' /srv/nfs/backup-metrics/backup.prom 2>/dev/null \
    || log "no metrics file yet (backups have never run)"
else
  log "the backup stack is not deployed"
fi

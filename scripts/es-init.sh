#!/usr/bin/env bash
# =============================================================================
# Elasticsearch initialisation (CDC §7.4).
#
#   scripts/es-init.sh            (called by deploy.sh after `data`)
#
# Idempotent by construction: every call is a PUT of a desired state, so
# re-running it after a redeploy or during a disaster-recovery drill converges
# instead of failing.
#
# What it does, in order:
#   1. wait for the cluster to be green (or yellow, with an explanation);
#   2. set the built-in and application passwords;
#   3. create the application roles and users;
#   4. install the ILM policies;
#   5. install the component and index templates;
#   6. create the data streams;
#   7. register the S3 snapshot repository on MinIO, and the SLM policy;
#   8. provision the Kibana data views;
#   9. verify.
#
# Step 7 depends on MinIO, which is deployed LATER (the `backup` stack). That
# is handled, not ignored: the repository registration is skipped with a clear
# message when MinIO is not reachable, and `scripts/minio-init.sh` calls this
# script back to finish the job.
# =============================================================================
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

need_manager
load_env
cd "$DW_ROOT"

readonly STACK=data
readonly ES_MEMBERS=(es-1 es-2 es-3)

# -----------------------------------------------------------------------------
# Locate a running Elasticsearch container on this node and talk to it through
# `docker exec` + curl. That avoids exposing the ES port anywhere and keeps the
# credentials inside the container.
# -----------------------------------------------------------------------------
find_container() {
  local m cid
  for m in "${ES_MEMBERS[@]}"; do
    cid="$(docker ps -q --filter "label=com.docker.swarm.service.name=${STACK}_${m}" | head -1)"
    if [[ -n "$cid" ]]; then printf '%s' "$cid"; return 0; fi
  done
  return 1
}

CID="$(find_container || true)"
[[ -n "$CID" ]] || die "no Elasticsearch task on $(hostname) — run this from a node hosting one"
info "using the Elasticsearch container ${CID:0:12}"

# es_api METHOD PATH [BODY]
# Returns the response body; the HTTP status is checked by the caller through
# es_api_status when it matters.
es_api() {
  local method=$1 path=$2 body="${3:-}"
  # shellcheck disable=SC2016  # $(cat …) must expand INSIDE the container
  if [[ -n "$body" ]]; then
    docker exec -i "$CID" sh -c \
      'curl -s -u "elastic:$(cat /run/secrets/dw_es_elastic_password)" \
         -X '"$method"' -H "Content-Type: application/json" \
         "http://localhost:9200'"$path"'" -d @-' <<<"$body"
  else
    docker exec "$CID" sh -c \
      'curl -s -u "elastic:$(cat /run/secrets/dw_es_elastic_password)" \
         -X '"$method"' "http://localhost:9200'"$path"'"'
  fi
}

es_api_status() {
  local method=$1 path=$2 body="${3:-}"
  if [[ -n "$body" ]]; then
    docker exec -i "$CID" sh -c \
      'curl -s -o /dev/null -w "%{http_code}" -u "elastic:$(cat /run/secrets/dw_es_elastic_password)" \
         -X '"$method"' -H "Content-Type: application/json" \
         "http://localhost:9200'"$path"'" -d @-' <<<"$body"
  else
    docker exec "$CID" sh -c \
      'curl -s -o /dev/null -w "%{http_code}" -u "elastic:$(cat /run/secrets/dw_es_elastic_password)" \
         -X '"$method"' "http://localhost:9200'"$path"'"'
  fi
}

read_secret() {
  local value
  value="$(docker exec "$CID" sh -c "cat /run/secrets/$1 2>/dev/null" || true)"
  [[ -n "$value" ]] || die "secret $1 is unreadable inside the container"
  printf '%s' "$value"
}

# put_json PATH FILE — install a JSON document, stripping the `_comment` and
# `_meta` keys this repository uses for documentation. Elasticsearch rejects
# unknown top-level keys in an ILM policy, so they must go.
put_json() {
  local path=$1 file=$2 label=$3
  local body status
  body="$(python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
doc.pop("_comment", None)
doc.pop("_meta", None)
print(json.dumps(doc))' "$file")"
  status="$(es_api_status PUT "$path" "$body")"
  if [[ "$status" =~ ^2 ]]; then
    ok "${label}"
  else
    error "${label}: HTTP ${status}"
    es_api PUT "$path" "$body" | head -5 | sed 's/^/    /' >&2
    return 1
  fi
}

# =============================================================================
# 1. Cluster health
# =============================================================================
section "1/9 — cluster health"
elapsed=0
status=""
while (( elapsed < 600 )); do
  status="$(es_api GET '/_cat/health?h=status' | tr -d '[:space:]')"
  case "$status" in
    green)  ok "cluster green"; break ;;
    yellow) log "  yellow (replicas not yet allocated) …" ;;
    *)      log "  status='${status:-unreachable}' …" ;;
  esac
  sleep 10
  elapsed=$(( elapsed + 10 ))
done

if [[ "$status" == "yellow" ]]; then
  # Yellow on a brand-new cluster with no index is normal and transient. Yellow
  # with unassigned shards after 10 minutes is not.
  unassigned="$(es_api GET '/_cluster/health' | python3 -c 'import json,sys; print(json.load(sys.stdin)["unassigned_shards"])')"
  if (( unassigned == 0 )); then
    ok "cluster yellow with 0 unassigned shard — acceptable, no index yet"
  else
    warn "cluster yellow with ${unassigned} unassigned shard(s); continuing"
  fi
elif [[ "$status" != "green" ]]; then
  error "cluster status '${status}' after 600 s"
  es_api GET '/_cluster/health?pretty' | sed 's/^/    /' >&2
  exit 1
fi

nodes="$(es_api GET '/_cat/nodes?h=name' | tr -d ' ' | grep -c . || true)"
if [[ "$nodes" == "3" ]]; then
  ok "3 nodes in the cluster"
else
  warn "${nodes} node(s) in the cluster (expected 3)"
fi

# =============================================================================
# 2. Built-in passwords
#
# `kibana_system` is a built-in service account: it cannot be created, only
# given a password. Doing this every run also makes a secret rotation a matter
# of re-running the script.
# =============================================================================
section "2/9 — built-in accounts"
KIBANA_PW="$(read_secret dw_es_kibana_password)"
status="$(es_api_status POST '/_security/user/kibana_system/_password' \
  "$(python3 -c 'import json,sys; print(json.dumps({"password": sys.argv[1]}))' "$KIBANA_PW")")"
if [[ "$status" =~ ^2 ]]; then
  ok "kibana_system password set"
else
  die "kibana_system: HTTP ${status}"
fi

# =============================================================================
# 3. Roles and application users
#
# Each user gets the narrowest role that lets it do its job. This is the
# difference between "a compromised log shipper writes logs" and "a compromised
# log shipper deletes the datalake".
# =============================================================================
section "3/9 — roles and application users"

# fluentbit: write into the log data streams, and nothing else. No read: a log
# collector has no business reading back what it wrote.
es_api PUT '/_security/role/dw_logs_writer' '{
  "cluster": ["monitor", "manage_index_templates"],
  "indices": [{
    "names": ["logs-docker*", "logs-traefik*", "logs-system*"],
    "privileges": ["create_doc", "create_index", "auto_configure", "view_index_metadata"]
  }]
}' >/dev/null
ok "role dw_logs_writer (write-only on logs-*)"

# grafana: read-only on everything it charts.
es_api PUT '/_security/role/dw_reader' '{
  "cluster": ["monitor"],
  "indices": [{
    "names": ["logs-*", "datalake-*"],
    "privileges": ["read", "view_index_metadata"]
  }]
}' >/dev/null
ok "role dw_reader (read-only)"

# datalake_app: write into datalake-events only.
es_api PUT '/_security/role/dw_datalake_writer' '{
  "cluster": ["monitor"],
  "indices": [{
    "names": ["datalake-events*"],
    "privileges": ["create_doc", "create_index", "auto_configure", "view_index_metadata"]
  }]
}' >/dev/null
ok "role dw_datalake_writer"

# exporter: cluster-level monitoring, no document access at all.
es_api PUT '/_security/role/dw_exporter' '{
  "cluster": ["monitor"],
  "indices": [{"names": ["*"], "privileges": ["monitor"]}]
}' >/dev/null
ok "role dw_exporter (metrics only, no document read)"

create_user() {
  local user=$1 secret=$2 roles=$3 label=$4
  local pw body status
  pw="$(read_secret "$secret")"
  body="$(python3 -c '
import json, sys
print(json.dumps({"password": sys.argv[1], "roles": sys.argv[2].split(","),
                  "full_name": sys.argv[3]}))' "$pw" "$roles" "$label")"
  status="$(es_api_status PUT "/_security/user/${user}" "$body")"
  if [[ "$status" =~ ^2 ]]; then
    ok "user ${user} (${roles})"
  else
    die "user ${user}: HTTP ${status}"
  fi
}

create_user fluentbit    dw_es_fluentbit_password dw_logs_writer     "Fluent Bit log shipper"
create_user grafana      dw_es_grafana_password   dw_reader          "Grafana datasource"
create_user datalake_app dw_es_app_password       dw_datalake_writer "demo-producer"
create_user exporter     dw_es_exporter_password  dw_exporter        "Prometheus exporter"

# =============================================================================
# 4. ILM policies
# =============================================================================
section "4/9 — lifecycle policies (ILM)"
put_json '/_ilm/policy/dockerwarts-logs' \
  config/elasticsearch/ilm/dockerwarts-logs.json 'policy dockerwarts-logs (90 d)'
put_json '/_ilm/policy/dockerwarts-datalake' \
  config/elasticsearch/ilm/dockerwarts-datalake.json 'policy dockerwarts-datalake (365 d)'

# =============================================================================
# 5. Templates
#
# The component template MUST be installed before the index templates that
# compose it, or the PUT is rejected.
# =============================================================================
section "5/9 — index templates"
put_json '/_component_template/dockerwarts-logs-common' \
  config/elasticsearch/templates/logs-common.json 'component template logs-common'

for t in logs-docker logs-traefik logs-system datalake-events; do
  put_json "/_index_template/dockerwarts-${t}" \
    "config/elasticsearch/templates/${t}.json" "index template ${t}"
done

# =============================================================================
# 6. Data streams
#
# Created explicitly rather than left to auto-creation: `action.auto_create_index`
# is restricted in elasticsearch.yml (a typo in a client must not create an
# unmapped index), so the streams must exist before anything writes to them.
# =============================================================================
section "6/9 — data streams"
for ds in logs-docker logs-traefik logs-system datalake-events; do
  status="$(es_api_status PUT "/_data_stream/${ds}")"
  case "$status" in
    2*)  ok "data stream ${ds} created" ;;
    400) ok "data stream ${ds} already exists" ;;
    *)   error "data stream ${ds}: HTTP ${status}"
         es_api PUT "/_data_stream/${ds}" | head -3 | sed 's/^/    /' >&2
         exit 1 ;;
  esac
done

# =============================================================================
# 7. Snapshot repository and SLM
#
# Depends on MinIO (the `backup` stack). Skipped cleanly when it is not there
# yet; scripts/minio-init.sh re-runs this script to finish the job.
# =============================================================================
section "7/9 — snapshots (MinIO S3 repository + SLM)"
if docker service ls --format '{{.Name}}' | grep -q '^backup_minio$'; then
  # The S3 credentials go into the Elasticsearch KEYSTORE, not into the
  # repository definition: a repository definition is readable through the API
  # by anyone with `monitor`, a keystore entry is not.
  info "loading the S3 credentials into the keystore"
  docker exec "$CID" sh -c '
    set -e
    printf "%s" "$(cat /run/secrets/dw_minio_es_key)" \
      | elasticsearch-keystore add --stdin --force s3.client.default.access_key
    printf "%s" "$(cat /run/secrets/dw_minio_es_secret)" \
      | elasticsearch-keystore add --stdin --force s3.client.default.secret_key
  ' >/dev/null 2>&1 || warn "keystore not updated — is the MinIO secret attached to es-*?"

  # Reload the secure settings on every node without a restart.
  es_api POST '/_nodes/reload_secure_settings' \
    "$(python3 -c 'import json,sys; print(json.dumps({"secure_settings_password": ""}))')" >/dev/null 2>&1 || true

  put_status="$(es_api_status PUT '/_snapshot/minio' '{
    "type": "s3",
    "settings": {
      "bucket": "es-snapshots",
      "endpoint": "minio:9000",
      "protocol": "http",
      "path_style_access": true,
      "compress": true,
      "max_restore_bytes_per_sec": "80mb",
      "max_snapshot_bytes_per_sec": "40mb"
    }
  }')"
  if [[ "$put_status" =~ ^2 ]]; then
    ok "repository 'minio' registered"
    # `verify` actually writes and reads a test blob: a repository that
    # registers but cannot be written to is the classic silent backup failure.
    if es_api POST '/_snapshot/minio/_verify' | grep -q '"nodes"'; then
      ok "repository verified (write + read)"
    else
      warn "the repository registered but verification failed — check the MinIO credentials"
    fi
    put_json '/_slm/policy/daily-snapshots' config/elasticsearch/slm.json 'SLM policy daily-snapshots'
  else
    warn "repository not registered (HTTP ${put_status}) — re-run after: make deploy-backup"
  fi
else
  warn "MinIO is not deployed yet: repository and SLM skipped"
  warn "  they will be created by scripts/minio-init.sh (make deploy-backup)"
fi

# =============================================================================
# 8. Kibana data views
#
# Provisioned through the saved-objects API so that an operator opening Kibana
# finds Discover already usable, rather than an empty "create a data view"
# prompt.
# =============================================================================
section "8/9 — Kibana data views"
KID="$(docker ps -q --filter "label=com.docker.swarm.service.name=${STACK}_kibana" | head -1)"
if [[ -n "$KID" ]]; then
  create_data_view() {
    local id=$1 title=$2 tf=$3
    local body
    body="$(python3 -c '
import json, sys
print(json.dumps({"data_view": {"id": sys.argv[1], "title": sys.argv[2],
                                "timeFieldName": sys.argv[3], "name": sys.argv[2]}}))' \
      "$id" "$title" "$tf")"
    local code
    code="$(docker exec -i "$KID" sh -c \
      'curl -s -o /dev/null -w "%{http_code}" -X POST \
         -u "elastic:'"$(read_secret dw_es_elastic_password)"'" \
         -H "kbn-xsrf: true" -H "Content-Type: application/json" \
         "http://localhost:5601/api/data_views/data_view" -d @-' <<<"$body")"
    case "$code" in
      2*)  ok "data view ${title}" ;;
      409) ok "data view ${title} already exists" ;;
      *)   warn "data view ${title}: HTTP ${code}" ;;
    esac
  }
  create_data_view dw-logs   'logs-*'           '@timestamp'
  create_data_view dw-events 'datalake-events*' '@timestamp'
else
  warn "no Kibana task on this node — data views skipped (re-run from the right node)"
fi

# =============================================================================
# 9. Verification
# =============================================================================
section "9/9 — verification"
for policy in dockerwarts-logs dockerwarts-datalake; do
  if es_api GET "/_ilm/policy/${policy}" | grep -q '"policy"'; then
    ok "ILM ${policy}"
  else
    die "ILM ${policy} is missing"
  fi
done
for t in logs-docker logs-traefik logs-system datalake-events; do
  if es_api GET "/_data_stream/${t}" | grep -q '"name"'; then
    ok "data stream ${t}"
  else
    die "data stream ${t} is missing"
  fi
done
# The ILM policy must actually be ATTACHED to the stream's backing index —
# a policy that exists but is not applied silently retains data forever.
attached="$(es_api GET '/logs-docker/_settings?flat_settings=true' \
  | grep -c '"index.lifecycle.name":"dockerwarts-logs"' || true)"
if (( attached > 0 )); then
  ok "the ILM policy is attached to logs-docker"
else
  warn "logs-docker does not carry index.lifecycle.name — check the template"
fi

ok "Elasticsearch initialised"

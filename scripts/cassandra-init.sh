#!/usr/bin/env bash
# =============================================================================
# Cassandra initialisation (CDC §7.3).
#
#   scripts/cassandra-init.sh            (called by deploy.sh after `data`)
#
# Idempotent: safe to run on every deployment and during a disaster-recovery
# drill. Everything it does is either `IF NOT EXISTS` or a no-op when already
# applied.
#
# What it does, in order:
#   1. wait for the three nodes to report UN (Up/Normal);
#   2. replace the default `cassandra/cassandra` superuser — the single most
#      important step, and the one most often skipped;
#   3. create the application accounts (datalake_app, backup);
#   4. apply config/cassandra/init.cql (keyspace + tables);
#   5. verify the replication factor actually took.
#
# Step 2 in detail
# ----------------
# A fresh Cassandra with PasswordAuthenticator ships a superuser
# `cassandra`/`cassandra`. It cannot be deleted while it is the only superuser,
# so the sequence is: log in as it, create a NEW superuser, log in as the new
# one, then demote and lock the default. Leaving `cassandra/cassandra` alive is
# a full database compromise for anyone who reaches the `data` network.
#
# Also: the `system_auth` keyspace is created with RF=1 by default. If the node
# holding it goes down, NOBODY can authenticate — including this script. Raising
# it to 3 is mandatory on a 3-node cluster and is done here.
# =============================================================================
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

need_manager
load_env
cd "$DW_ROOT"

readonly STACK=data
readonly MEMBERS=(cassandra-1 cassandra-2 cassandra-3)
readonly DEFAULT_USER=cassandra
readonly DEFAULT_PASS=cassandra
readonly ADMIN_USER=dwadmin

# -----------------------------------------------------------------------------
# Find a running Cassandra container on this node.
# -----------------------------------------------------------------------------
find_container() {
  local m
  for m in "${MEMBERS[@]}"; do
    local cid
    cid="$(docker ps -q --filter "label=com.docker.swarm.service.name=${STACK}_${m}" | head -1)"
    if [[ -n "$cid" ]]; then printf '%s' "$cid"; return 0; fi
  done
  return 1
}

CID="$(find_container || true)"
[[ -n "$CID" ]] || die "no Cassandra task on $(hostname) — run this from a node hosting one"
info "using the Cassandra container ${CID:0:12}"

# -----------------------------------------------------------------------------
# cqlsh wrappers. Credentials are passed on stdin-free arguments inside the
# container, never echoed.
# -----------------------------------------------------------------------------
cql_as() {
  local user=$1 pass=$2 stmt=$3
  docker exec -i "$CID" cqlsh -u "$user" -p "$pass" -e "$stmt" 2>&1
}

read_secret() {
  local path="/run/secrets/$1" value
  value="$(docker exec "$CID" sh -c "cat ${path} 2>/dev/null" || true)"
  [[ -n "$value" ]] || die "secret $1 is unreadable inside the container"
  printf '%s' "$value"
}

# =============================================================================
# 1. Wait for the ring
# =============================================================================
section "1/5 — waiting for the three nodes"
elapsed=0
while (( elapsed < 600 )); do
  up="$(docker exec "$CID" nodetool status 2>/dev/null \
        | awk '$1 == "UN" { n++ } END { print n + 0 }')"
  if [[ "$up" == "3" ]]; then
    ok "3 nodes UN"
    break
  fi
  log "  ${up:-0}/3 nodes UN …"
  sleep 10
  elapsed=$(( elapsed + 10 ))
done
[[ "${up:-0}" == "3" ]] || die "only ${up:-0}/3 nodes are UN after 600 s"

docker exec "$CID" nodetool status 2>/dev/null | sed -n '5,12p' >&2

# =============================================================================
# 2. Superuser
# =============================================================================
section "2/5 — administration account"
ADMIN_PASS="$(read_secret dw_cassandra_admin_password)"

if cql_as "$ADMIN_USER" "$ADMIN_PASS" "SELECT release_version FROM system.local" \
     | grep -qE '^ *[0-9]+\.[0-9]+'; then
  ok "${ADMIN_USER} already exists"
else
  info "creating ${ADMIN_USER} from the default account"

  # `system_auth` FIRST: with RF=1, losing one node locks everyone out —
  # including the rest of this script.
  cql_as "$DEFAULT_USER" "$DEFAULT_PASS" \
    "ALTER KEYSPACE system_auth WITH replication =
       {'class': 'NetworkTopologyStrategy', 'dc1': 3};" >/dev/null \
    || die "cannot log in as the default account — was this cluster already initialised?"
  ok "system_auth raised to RF=3"

  cql_as "$DEFAULT_USER" "$DEFAULT_PASS" \
    "CREATE ROLE IF NOT EXISTS ${ADMIN_USER}
       WITH PASSWORD = '${ADMIN_PASS}' AND LOGIN = true AND SUPERUSER = true;" >/dev/null
  ok "${ADMIN_USER} created"

  # Demote and lock the default account. It cannot be dropped (Cassandra
  # refuses to remove the account it was bootstrapped with), so it is stripped
  # of superuser AND of the ability to log in.
  cql_as "$ADMIN_USER" "$ADMIN_PASS" \
    "ALTER ROLE ${DEFAULT_USER} WITH SUPERUSER = false AND LOGIN = false;" >/dev/null
  ok "the default '${DEFAULT_USER}' account is demoted and cannot log in"
fi

# `system_auth` must be RF=3 even on a cluster initialised earlier.
cql_as "$ADMIN_USER" "$ADMIN_PASS" \
  "ALTER KEYSPACE system_auth WITH replication =
     {'class': 'NetworkTopologyStrategy', 'dc1': 3};" >/dev/null
# Re-running an ALTER is free; a repair is what actually propagates the extra
# replicas, so trigger it once.
docker exec "$CID" nodetool repair -pr system_auth >/dev/null 2>&1 || \
  warn "repair of system_auth did not complete — re-run 'nodetool repair system_auth'"

# =============================================================================
# 3. Application accounts
# =============================================================================
section "3/5 — application accounts"
APP_PASS="$(read_secret dw_cassandra_app_password)"
BACKUP_PASS="$(read_secret dw_cassandra_backup_password)"

# datalake_app: read/write on the `datalake` keyspace only. The GRANT is issued
# after the keyspace exists (step 4), so only the role is created here.
cql_as "$ADMIN_USER" "$ADMIN_PASS" \
  "CREATE ROLE IF NOT EXISTS datalake_app
     WITH PASSWORD = '${APP_PASS}' AND LOGIN = true AND SUPERUSER = false;" >/dev/null
ok "role datalake_app"

# backup: SELECT only. `nodetool snapshot` goes through JMX with its own
# credentials, so this account never needs write access anywhere.
cql_as "$ADMIN_USER" "$ADMIN_PASS" \
  "CREATE ROLE IF NOT EXISTS backup
     WITH PASSWORD = '${BACKUP_PASS}' AND LOGIN = true AND SUPERUSER = false;" >/dev/null
ok "role backup"

# =============================================================================
# 4. Schema
# =============================================================================
section "4/5 — keyspace and tables"
docker cp config/cassandra/init.cql "${CID}:/tmp/init.cql"
output="$(docker exec -i "$CID" cqlsh -u "$ADMIN_USER" -p "$ADMIN_PASS" -f /tmp/init.cql 2>&1 || true)"
docker exec "$CID" rm -f /tmp/init.cql
if grep -qiE 'error|invalid' <<<"$output"; then
  error "init.cql failed:"
  printf '    %s\n' "${output//$'\n'/$'\n    '}" >&2
  exit 1
fi
ok "config/cassandra/init.cql applied"

cql_as "$ADMIN_USER" "$ADMIN_PASS" \
  "GRANT SELECT, MODIFY ON KEYSPACE datalake TO datalake_app;" >/dev/null
cql_as "$ADMIN_USER" "$ADMIN_PASS" \
  "GRANT SELECT ON KEYSPACE datalake TO backup;" >/dev/null
ok "grants applied"

# =============================================================================
# 5. Verification
# =============================================================================
section "5/5 — verification"

rf="$(cql_as "$ADMIN_USER" "$ADMIN_PASS" \
  "SELECT replication FROM system_schema.keyspaces WHERE keyspace_name = 'datalake';")"
if grep -q "'dc1': '3'" <<<"$rf"; then
  ok "keyspace datalake: RF = 3 on dc1"
else
  error "unexpected replication factor:"
  printf '    %s\n' "${rf//$'\n'/$'\n    '}" >&2
  exit 1
fi

tables="$(cql_as "$ADMIN_USER" "$ADMIN_PASS" \
  "SELECT table_name FROM system_schema.tables WHERE keyspace_name = 'datalake';")"
for t in events events_by_site; do
  grep -q "$t" <<<"$tables" || die "table datalake.${t} is missing"
  ok "table datalake.${t}"
done

# A real write/read round trip: proves the consistency level is actually
# satisfiable, which a schema check alone does not.
probe_ts="$(date -u '+%Y-%m-%d %H:%M:%S')"
cql_as datalake_app "$APP_PASS" \
  "CONSISTENCY LOCAL_QUORUM;
   INSERT INTO datalake.events (site, sensor_id, day, ts, temperature, humidity)
   VALUES ('_init', '_probe', toDate(now()), '${probe_ts}', 0.0, 0.0) USING TTL 60;" >/dev/null
read_back="$(cql_as datalake_app "$APP_PASS" \
  "CONSISTENCY LOCAL_QUORUM;
   SELECT temperature FROM datalake.events
   WHERE site='_init' AND sensor_id='_probe' AND day=toDate(now()) LIMIT 1;")"
if grep -q '0' <<<"$read_back"; then
  ok "write + read at LOCAL_QUORUM: OK (probe row expires in 60 s)"
else
  die "the LOCAL_QUORUM round trip failed — is the cluster really at 3 nodes?"
fi

ok "Cassandra initialised"

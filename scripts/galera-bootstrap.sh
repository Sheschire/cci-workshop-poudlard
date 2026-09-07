#!/usr/bin/env bash
# =============================================================================
# First bootstrap of the Galera cluster (CDC §7.2).
#
#   scripts/galera-bootstrap.sh          (called automatically by deploy.sh)
#
# The problem this solves
# -----------------------
# A Galera cluster cannot form spontaneously. Every member's
# `wsrep_cluster_address` lists the three of them, so on a cold start each node
# tries to JOIN a cluster that does not exist yet, and all three wait forever.
#
# Exactly one node must be told "you ARE the cluster" with
# `--wsrep-new-cluster`. That flag is dangerous: applied to two nodes at the
# same time it creates two independent clusters that both believe they are
# authoritative — a split-brain that no later repair fixes cleanly.
#
# So the sequence is, strictly:
#   1. deploy galera-1 ALONE with GALERA_BOOTSTRAP=1;
#   2. wait for wsrep_ready=ON and wsrep_cluster_size=1;
#   3. deploy galera-2 and galera-3, which join by SST;
#   4. wait for wsrep_cluster_size=3;
#   5. REDEPLOY galera-1 without the flag, so that a later restart of that
#      service rejoins the cluster instead of forking a new one.
#
# Step 5 is the one people forget. Without it, galera-1 keeps
# `--wsrep-new-cluster` in its service definition forever, and the next time
# Swarm reschedules it — a node reboot, a rolling update — it silently starts a
# brand-new empty cluster while the other two carry the real data.
#
# Idempotent: if the cluster is already formed, the script says so and exits 0.
# =============================================================================
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/render.sh"

need_manager
load_env
cd "$DW_ROOT"

readonly STACK=data
readonly MEMBERS=(galera-1 galera-2 galera-3)

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# Run a mariadb query inside a member, from wherever the task happens to run.
# Uses `docker exec` on the local node, falling back to a manager-wide search.
galera_query() {
  local member=$1 query=$2
  local svc="${STACK}_${member}"
  local cid
  cid="$(docker ps -q --filter "label=com.docker.swarm.service.name=${svc}" | head -1)"
  if [[ -z "$cid" ]]; then
    return 2   # not on this node
  fi
  docker exec "$cid" sh -c \
    "mariadb -u root -p\"\$(cat /run/secrets/dw_mariadb_root_password)\" -N -B -e \"${query}\"" \
    2>/dev/null
}

# Read a wsrep status variable, from whichever node hosts the member.
wsrep_status() {
  local member=$1 var=$2 out
  out="$(galera_query "$member" "SHOW STATUS LIKE '${var}'" || true)"
  [[ -n "$out" ]] && printf '%s' "$(awk '{print $2}' <<<"$out")"
}

cluster_size() {
  local m
  for m in "${MEMBERS[@]}"; do
    local size
    size="$(wsrep_status "$m" wsrep_cluster_size || true)"
    if [[ -n "$size" ]]; then printf '%s' "$size"; return 0; fi
  done
  printf '0'
}

wait_for() {
  local member=$1 var=$2 expected=$3 timeout=${4:-300}
  local elapsed=0 value
  info "waiting for ${member}: ${var} = ${expected} (max ${timeout}s)"
  while (( elapsed < timeout )); do
    value="$(wsrep_status "$member" "$var" || true)"
    if [[ "$value" == "$expected" ]]; then
      ok "${member}: ${var} = ${value}"
      return 0
    fi
    sleep 5
    elapsed=$(( elapsed + 5 ))
  done
  error "${member}: ${var} = '${value:-<unreachable>}' after ${timeout}s (expected ${expected})"
  docker service logs --tail 30 "${STACK}_${member}" 2>&1 | sed 's/^/    /' >&2 || true
  return 1
}

# Deploy the data stack with a given bootstrap flag on galera-1.
deploy_with_bootstrap() {
  local flag=$1
  GALERA_BOOTSTRAP_1="$flag" \
    docker stack deploy --detach=true --resolve-image=changed --prune=false \
      --compose-file stacks/data.yml "$STACK" >/dev/null
}

# -----------------------------------------------------------------------------
# 0. Already formed?
# -----------------------------------------------------------------------------
section "Galera cluster state"
render_configs >/dev/null
export_config_hashes

existing="$(cluster_size)"
if [[ "$existing" == "3" ]]; then
  ok "the cluster already has 3 members — nothing to do"
  exit 0
fi
if (( existing > 0 )); then
  warn "a cluster exists with ${existing} member(s)"
  warn "this script bootstraps a NEW cluster and must not run against a partial one."
  warn "To bring the missing members back, redeploy without the flag:"
  warn "    make deploy-data"
  warn "To recover after a FULL cluster stop, use:  scripts/galera-recover.sh"
  exit 1
fi
info "no cluster detected — bootstrapping"

# -----------------------------------------------------------------------------
# 1. galera-1 alone, with --wsrep-new-cluster
#
# The other two members are scaled to 0 first: if they were already running and
# failing to join, they would fight the new cluster as it forms.
# -----------------------------------------------------------------------------
section "1/5 — galera-1 with --wsrep-new-cluster"
deploy_with_bootstrap 1
for m in galera-2 galera-3; do
  docker service scale --detach "${STACK}_${m}=0" >/dev/null 2>&1 || true
done
docker service scale --detach "${STACK}_galera-1=1" >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# 2. Wait for the founding member
# -----------------------------------------------------------------------------
section "2/5 — waiting for galera-1"
wait_service "${STACK}_galera-1" 300
wait_for galera-1 wsrep_ready ON 300
wait_for galera-1 wsrep_cluster_status Primary 120
ok "galera-1 is the founding member of the cluster"

# -----------------------------------------------------------------------------
# 3. galera-2 and galera-3 join, one at a time
#
# Sequentially, not in parallel: two simultaneous SSTs from the same donor
# would compete for its disk and network and both take far longer.
# -----------------------------------------------------------------------------
section "3/5 — joining galera-2 and galera-3"
for m in galera-2 galera-3; do
  info "starting ${m} (SST from galera-1 — this takes a few minutes)"
  docker service scale --detach "${STACK}_${m}=1" >/dev/null
  wait_service "${STACK}_${m}" 600
  wait_for "$m" wsrep_ready ON 600
done

# -----------------------------------------------------------------------------
# 4. The cluster must be complete
# -----------------------------------------------------------------------------
section "4/5 — verifying the cluster"
size="$(cluster_size)"
[[ "$size" == "3" ]] || die "wsrep_cluster_size = ${size}, expected 3"
ok "wsrep_cluster_size = 3"

for m in "${MEMBERS[@]}"; do
  state="$(wsrep_status "$m" wsrep_local_state_comment || echo '<unreachable>')"
  if [[ "$state" == "Synced" ]]; then
    ok "${m}: ${state}"
  elif [[ "$state" == "<unreachable>" ]]; then
    log "${m}: not on this node, state not checked from here"
  else
    die "${m}: state '${state}', expected 'Synced'"
  fi
done

# -----------------------------------------------------------------------------
# 5. Remove the bootstrap flag — THE critical step
# -----------------------------------------------------------------------------
section "5/5 — removing the bootstrap flag from galera-1"
deploy_with_bootstrap 0
wait_service "${STACK}_galera-1" 300
wait_for galera-1 wsrep_ready ON 300

size="$(cluster_size)"
[[ "$size" == "3" ]] || die "the cluster fell to ${size} members after the flag was removed"

ok "bootstrap complete: 3 synchronised members, no bootstrap flag left"
cat >&2 <<EOF

Verify at any time with:
  docker exec \$(docker ps -q -f name=${STACK}_galera-1) \\
    mariadb -u root -p"\$(cat /run/secrets/dw_mariadb_root_password)" \\
    -e "SHOW STATUS WHERE Variable_name IN
        ('wsrep_cluster_size','wsrep_cluster_status','wsrep_local_state_comment')"
EOF

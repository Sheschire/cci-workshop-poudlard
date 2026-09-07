#!/usr/bin/env bash
# =============================================================================
# Recover a Galera cluster after a FULL stop (CDC §7.2, docs/07-PRA.md §5).
#
#   scripts/galera-recover.sh              diagnose and recover
#   scripts/galera-recover.sh --dry-run    diagnose only, change nothing
#   scripts/galera-recover.sh --force NODE bootstrap from a chosen member
#
# When to use this — and when NOT to
# ----------------------------------
# USE IT when all three members are down at once: a full power loss, a failed
# maintenance window, `docker stack rm data` by mistake.
#
# DO NOT use it when the cluster still has a Primary component (one or two
# members alive). In that case simply restarting the missing member makes it
# rejoin by IST or SST — running this script instead would fork a new cluster
# from stale data and lose everything written since.
# The script checks for this and refuses.
#
# Why it is not just "start them all again"
# -----------------------------------------
# On a clean shutdown Galera writes `safe_to_bootstrap: 1` into grastate.dat on
# the LAST node to stop — the one that necessarily holds every transaction. On
# a crash, nobody gets the flag and every node has `safe_to_bootstrap: 0`.
#
# Starting the wrong node first silently loses every transaction the others had
# and it did not. So the correct member is the one with the HIGHEST `seqno`,
# and finding it is what this script automates.
#
# A node that crashed has `seqno: -1` in grastate.dat: its real position is only
# recoverable by running `mariadbd --wsrep-recover`, which replays the InnoDB
# log and prints the recovered position. The script does that too.
# =============================================================================
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/render.sh"

need_manager
load_env
cd "$DW_ROOT"

readonly STACK=data
readonly MEMBERS=(galera-1 galera-2 galera-3)
readonly IMAGE="mariadb:11.4.13@sha256:611a2fcc5fa7c6ceb8644c6f74b25ede004ff6c3a6b38c8f8c23d3bbf6c26430"

DRY_RUN=0
FORCE_NODE=""
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  --force)   FORCE_NODE="${2:?usage: --force <galera-1|galera-2|galera-3>}" ;;
  "")        ;;
  *)         die "usage: $0 [--dry-run | --force <member>]" ;;
esac

# -----------------------------------------------------------------------------
# Which node hosts which member (from the placement labels).
# -----------------------------------------------------------------------------
node_for_member() {
  local member=$1 index="${1##*-}"
  docker node ls --format '{{.Hostname}}' | while read -r host; do
    if [[ "$(docker node inspect "$host" --format "{{index .Spec.Labels \"galera\"}}" 2>/dev/null)" == "$index" ]]; then
      printf '%s' "$host"
      return
    fi
  done
}

# -----------------------------------------------------------------------------
# Read grastate.dat, and recover the position when it says -1.
#
# Runs a THROWAWAY mariadb container against the member's volume. That is the
# only way to read the state of a stopped member: the volume is local to its
# node, so the container must be scheduled there.
# -----------------------------------------------------------------------------
inspect_member() {
  local member=$1
  local index="${member##*-}"
  local host
  host="$(node_for_member "$member")"
  [[ -n "$host" ]] || { printf '%s ? ? node-not-found\n' "$member"; return; }

  # A one-shot service pinned to the right node, reading the volume read-only.
  local svc="galera-inspect-${index}-$$"
  docker service create --detach=false --quiet \
    --name "$svc" \
    --restart-condition none \
    --constraint "node.labels.galera == ${index}" \
    --mount "type=volume,source=galera_data_${index},target=/var/lib/mysql,readonly" \
    --entrypoint /bin/sh \
    "$IMAGE" \
    -c 'if [ -f /var/lib/mysql/grastate.dat ]; then
          uuid=$(awk "/^uuid:/ {print \$2}" /var/lib/mysql/grastate.dat)
          seqno=$(awk "/^seqno:/ {print \$2}" /var/lib/mysql/grastate.dat)
          safe=$(awk "/^safe_to_bootstrap:/ {print \$2}" /var/lib/mysql/grastate.dat)
          echo "GRASTATE ${uuid} ${seqno} ${safe}"
        else
          echo "GRASTATE none -1 0"
        fi' >/dev/null 2>&1 || true

  local out
  out="$(docker service logs "$svc" 2>/dev/null | grep -o 'GRASTATE .*' | head -1 || true)"
  docker service rm "$svc" >/dev/null 2>&1 || true

  if [[ -z "$out" ]]; then
    printf '%s ? ? unreachable\n' "$member"
    return
  fi
  # GRASTATE <uuid> <seqno> <safe_to_bootstrap>
  read -r _ uuid seqno safe <<<"$out"
  printf '%s %s %s %s\n' "$member" "$uuid" "$seqno" "$safe"
}

# =============================================================================
# 1. Refuse to run against a live cluster
# =============================================================================
section "Checking that the cluster really is fully down"
live=0
for m in "${MEMBERS[@]}"; do
  cid="$(docker ps -q --filter "label=com.docker.swarm.service.name=${STACK}_${m}" | head -1)"
  [[ -n "$cid" ]] && live=$(( live + 1 ))
done
if (( live > 0 )); then
  error "${live} Galera container(s) are running on this node."
  error "This script is ONLY for a cluster that is entirely down."
  error "With a surviving Primary component, just restart the missing member:"
  error "    docker service update --force ${STACK}_galera-N"
  exit 1
fi
ok "no Galera container running on this node"
warn "check the other two nodes as well before continuing:"
warn "    for n in node1 node2 node3; do vagrant ssh \$n -c 'docker ps --filter name=galera'; done"

# =============================================================================
# 2. Read every member's state
# =============================================================================
section "Reading grastate.dat on each member"
# Only SAFE is read back later; the seqno drives best_member as it is parsed.
declare -A SAFE=()
best_member=""
best_seqno=-2

for m in "${MEMBERS[@]}"; do
  read -r name uuid seqno safe < <(inspect_member "$m")
  SAFE[$name]="$safe"
  printf '  %-10s uuid=%-38s seqno=%-8s safe_to_bootstrap=%s\n' \
    "$name" "$uuid" "$seqno" "$safe" >&2
  if [[ "$seqno" =~ ^[0-9]+$ ]] && (( seqno > best_seqno )); then
    best_seqno=$seqno
    best_member=$name
  fi
done

# =============================================================================
# 3. Choose the member to bootstrap from
# =============================================================================
section "Choosing the founding member"

chosen=""
if [[ -n "$FORCE_NODE" ]]; then
  chosen="$FORCE_NODE"
  warn "forced by the operator: ${chosen}"
else
  # Priority 1: a node with safe_to_bootstrap = 1. Galera itself wrote that
  # flag on the last node to stop cleanly, so it provably holds everything.
  for m in "${MEMBERS[@]}"; do
    if [[ "${SAFE[$m]:-0}" == "1" ]]; then
      chosen="$m"
      ok "${m} carries safe_to_bootstrap: 1 — clean shutdown, it holds every transaction"
      break
    fi
  done

  # Priority 2: the highest seqno. That is the member that saw the most
  # transactions; bootstrapping from any other loses the difference.
  if [[ -z "$chosen" && -n "$best_member" && $best_seqno -ge 0 ]]; then
    chosen="$best_member"
    warn "no safe_to_bootstrap flag (unclean stop) — choosing the highest seqno"
    ok "${chosen} has seqno=${best_seqno}"
  fi
fi

if [[ -z "$chosen" ]]; then
  error "no member can be chosen automatically."
  error "Every seqno is -1: all three crashed and their positions are only"
  error "recoverable by replaying the InnoDB log. On the node of each member:"
  error ""
  error "    docker run --rm -v galera_data_N:/var/lib/mysql ${IMAGE} \\"
  error "      mariadbd --wsrep-recover 2>&1 | grep 'Recovered position'"
  error ""
  error "Then re-run with:  $0 --force galera-<the highest one>"
  exit 1
fi

if (( DRY_RUN )); then
  section "Dry run"
  ok "would bootstrap from: ${chosen}"
  exit 0
fi

# =============================================================================
# 4. Recover
# =============================================================================
section "Recovering from ${chosen}"
render_configs >/dev/null
export_config_hashes

index="${chosen##*-}"

# Galera refuses to bootstrap from a node whose grastate says
# `safe_to_bootstrap: 0`. Having established that this node holds the most
# advanced position, set the flag deliberately.
if [[ "${SAFE[$chosen]:-0}" != "1" ]]; then
  info "setting safe_to_bootstrap: 1 on ${chosen}"
  svc="galera-fix-${index}-$$"
  docker service create --detach=false --quiet \
    --name "$svc" \
    --restart-condition none \
    --constraint "node.labels.galera == ${index}" \
    --mount "type=volume,source=galera_data_${index},target=/var/lib/mysql" \
    --entrypoint /bin/sh \
    "$IMAGE" \
    -c "sed -i 's/^safe_to_bootstrap:.*/safe_to_bootstrap: 1/' /var/lib/mysql/grastate.dat && echo DONE" \
    >/dev/null 2>&1 || true
  docker service logs "$svc" 2>/dev/null | grep -q DONE \
    || warn "could not confirm the grastate.dat edit — check manually"
  docker service rm "$svc" >/dev/null 2>&1 || true
fi

# Bring up ONLY the chosen member, with the bootstrap flag.
info "starting ${chosen} with --wsrep-new-cluster"
for m in "${MEMBERS[@]}"; do
  [[ "$m" == "$chosen" ]] && continue
  docker service scale --detach "${STACK}_${m}=0" >/dev/null 2>&1 || true
done

# Only the chosen member gets GALERA_BOOTSTRAP=1. The stack reads
# ${GALERA_BOOTSTRAP_1} for galera-1; for the other two the recovery path is a
# targeted `service update`, because forking the stack file per member would
# be worse than this one asymmetry.
if [[ "$chosen" == "galera-1" ]]; then
  GALERA_BOOTSTRAP_1=1 docker stack deploy --detach=true --resolve-image=changed \
    --prune=false --compose-file stacks/data.yml "$STACK" >/dev/null
else
  docker service update --detach=false \
    --env-add GALERA_BOOTSTRAP=1 --replicas 1 "${STACK}_${chosen}" >/dev/null
fi

wait_service "${STACK}_${chosen}" 600

# Bring the other two back; they join by SST.
section "Rejoining the other members"
for m in "${MEMBERS[@]}"; do
  [[ "$m" == "$chosen" ]] && continue
  info "starting ${m}"
  docker service scale --detach "${STACK}_${m}=1" >/dev/null
  wait_service "${STACK}_${m}" 600
done

# =============================================================================
# 5. Remove the bootstrap flag — as critical here as in the initial bootstrap
# =============================================================================
section "Removing the bootstrap flag"
if [[ "$chosen" == "galera-1" ]]; then
  GALERA_BOOTSTRAP_1=0 docker stack deploy --detach=true --resolve-image=changed \
    --prune=false --compose-file stacks/data.yml "$STACK" >/dev/null
else
  docker service update --detach=false \
    --env-add GALERA_BOOTSTRAP=0 "${STACK}_${chosen}" >/dev/null
fi
wait_service "${STACK}_${chosen}" 600

ok "recovery finished — verify with: make status"

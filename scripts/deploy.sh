#!/usr/bin/env bash
# =============================================================================
# `make deploy` / `make deploy-<stack>` / `make single` — the deployment driver.
#
#   scripts/deploy.sh all                edge → data → apps → monitoring → backup
#   scripts/deploy.sh edge               one stack
#   scripts/deploy.sh --single all       single-node mode (workstation, NOT HA)
#   scripts/deploy.sh --no-wait edge     do not wait for health (debugging)
#
# What it does that `docker stack deploy` does not
# ------------------------------------------------
# 1. loads .env and exports the derived variables (JVM heaps from PROFILE);
# 2. renders the configuration files that need substitution into .rendered/
#    (scripts/lib/render.sh, shared with validate-stacks.sh so that what CI
#    validates is exactly what gets deployed);
# 3. computes a content hash per config file and exports it as
#    ${CONFIG_HASH_*}. Swarm configs are IMMUTABLE: without a name that
#    changes with the content, editing a config would silently do nothing.
#    With it, editing a file and redeploying rolls the services;
# 4. deploys in dependency order and waits for each stack to be healthy before
#    starting the next — Galera must be up before GLPI tries to install itself;
# 5. runs the one-shot initialisation jobs at the right point in the sequence;
# 6. prunes the config objects no service references any more.
# =============================================================================
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/render.sh"

# --- Options -----------------------------------------------------------------
SINGLE=0
WAIT=1
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --single)  SINGLE=1; shift ;;
    --no-wait) WAIT=0; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

TARGET="${1:-all}"
readonly STACK_ORDER=(edge data apps monitoring backup)

need_manager
load_env

cd "$DW_ROOT"

readonly OVERRIDE="${DW_ROOT}/stacks/overrides/single-node.yml"

# =============================================================================
# 1. Deploy one stack
# =============================================================================
deploy_stack() {
  local name=$1
  local file="stacks/${name}.yml"
  [[ -f "$file" ]] || { warn "stacks/${name}.yml does not exist yet — skipped"; return 0; }

  section "Deploying the '${name}' stack"

  local -a args=(--detach=true --with-registry-auth --prune --compose-file "$file")

  if (( SINGLE )) && [[ -f "$OVERRIDE" ]]; then
    # Single-node mode cannot be expressed by an override file alone, and this
    # was established on the merged output rather than assumed:
    #
    #   * `docker stack config` APPENDS an override's placement constraints to
    #     the base ones instead of replacing them. `constraints: []` changes
    #     nothing; a satisfiable constraint just gets added next to
    #     `node.labels.cassandra == 1`. Either way the task stays Pending on a
    #     workstation that carries no such label.
    #   * an override file ADDS its services to whatever stack it is merged
    #     with, so a single file covering the five stacks would inject
    #     image-less services (`minio` into `data`, …) that Swarm rejects.
    #
    # So the merge is materialised, filtered by scripts/lib/single-node.py, and
    # the filtered file is what gets deployed. `.rendered/` keeps it on disk:
    # when something behaves oddly in single-node mode, the exact YAML that was
    # deployed is there to read.
    local merged="${DW_RENDER_DIR}/single-${name}.yml"
    mkdir -p "$DW_RENDER_DIR"
    docker stack config --compose-file "$file" --compose-file "$OVERRIDE" \
      | python3 "${DW_LIB_DIR}/single-node.py" > "$merged"
    args=(--detach=true --with-registry-auth --prune --compose-file "$merged")
    warn "single-node mode: 1 replica per service, placement dropped — NOT highly available"
    log "  stack déployée : ${merged}"
  fi

  # `--prune` removes the services that disappeared from the file; `--resolve-image=changed`
  # only re-resolves a digest when the image reference changed, which keeps a
  # redeploy from restarting everything.
  docker stack deploy --resolve-image=changed "${args[@]}" "$name"
  ok "'${name}' stack submitted"
}

# =============================================================================
# 2. Wait for a stack to be healthy
#
# `docker stack deploy --detach=true` returns immediately. Deploying `apps`
# while Galera is still bootstrapping would make the GLPI installer fail, so
# each stack is waited on before the next starts.
# =============================================================================
wait_stack() {
  local name=$1 timeout=${2:-300}
  (( WAIT )) || { log "--no-wait: skipping the health check for '${name}'"; return 0; }

  section "Waiting for the '${name}' stack"
  local -a services
  mapfile -t services < <(docker stack services "$name" --format '{{.Name}}' 2>/dev/null | sort)
  (( ${#services[@]} > 0 )) || { warn "no service in '${name}'"; return 0; }

  local svc rc=0
  for svc in "${services[@]}"; do
    # A one-shot job (replicas: 0, restart: none) is driven by swarm-cronjob:
    # it is *supposed* to sit at 0/0 and must not be waited on.
    local mode
    mode="$(docker service inspect "$svc" --format '{{.Spec.Mode}}' 2>/dev/null || echo '')"
    if [[ "$mode" == *"Replicas:0"* ]]; then
      log "${svc}: scheduled job (0 replicas) — not waited on"
      continue
    fi
    wait_service "$svc" "$timeout" || rc=1
  done
  return "$rc"
}

# =============================================================================
# 3. One-shot initialisation jobs
#
# Each is idempotent and safe to re-run; they are invoked at the point of the
# sequence where their dependency is ready.
# =============================================================================
run_init() {
  local name=$1 script="scripts/${1}.sh"
  [[ -x "$script" ]] || { log "${script} does not exist yet — skipped"; return 0; }
  section "Initialisation: ${name}"
  "$script"
}

# =============================================================================
# 4. Prune orphaned config objects
#
# Content-hashed names mean every edit leaves the previous object behind.
# Anything no service references is removed; `docker config rm` refuses to
# delete one that is still in use, so this cannot break a running service.
# =============================================================================
prune_configs() {
  section "Pruning the orphaned configs"
  local -a in_use=()
  mapfile -t in_use < <(
    docker service ls -q \
      | xargs -r docker service inspect \
          --format '{{range .Spec.TaskTemplate.ContainerSpec.Configs}}{{.ConfigName}}{{"\n"}}{{end}}' \
      | sort -u
  )
  local removed=0 cfg
  while IFS= read -r cfg; do
    [[ -z "$cfg" ]] && continue
    # Only touch objects this project created (content-hash suffix).
    [[ "$cfg" =~ -[0-9a-f]{12}$ ]] || continue
    printf '%s\n' "${in_use[@]}" | grep -qxF "$cfg" && continue
    if docker config rm "$cfg" >/dev/null 2>&1; then
      (( ++removed ))
    fi
  done < <(docker config ls --format '{{.Name}}')
  ok "${removed} orphaned config(s) removed"
}

# =============================================================================
# Main
# =============================================================================
section "Rendering the configuration files"
render_configs
export_config_hashes

case "$TARGET" in
  registry|demo)
    deploy_stack "$TARGET"
    wait_stack "$TARGET"
    ;;

  edge|data|apps|monitoring|backup)
    deploy_stack "$TARGET"
    wait_stack "$TARGET"
    # A stack's own initialisation runs right after it is healthy.
    case "$TARGET" in
      data) run_init cassandra-init; run_init es-init ;;
      apps) run_init glpi-init ;;
      backup) run_init minio-init ;;
    esac
    ;;

  all)
    # ---- edge ----------------------------------------------------------------
    # First: it owns 80/443 and the VIP health check. Until Traefik answers
    # `/ping`, Keepalived keeps the VIP on node1 by priority alone.
    deploy_stack edge
    wait_stack edge 300

    # ---- data ----------------------------------------------------------------
    # Galera needs a controlled bootstrap (one node with --wsrep-new-cluster,
    # then the others, then the first one again without the flag). The regular
    # `stack deploy` cannot express that, hence the dedicated script.
    if [[ -x scripts/galera-bootstrap.sh ]] \
       && ! docker service ls --format '{{.Name}}' | grep -q '^data_galera-1$'; then
      section "First Galera bootstrap"
      scripts/galera-bootstrap.sh
    fi
    deploy_stack data
    wait_stack data 600      # Cassandra and Elasticsearch are slow to start
    run_init cassandra-init
    run_init es-init

    # ---- apps ----------------------------------------------------------------
    deploy_stack apps
    wait_stack apps 300
    run_init glpi-init

    # ---- monitoring ----------------------------------------------------------
    # After the applications: Prometheus discovers its targets through the
    # Swarm API, and GLPI must exist for alert2glpi to authenticate against it.
    deploy_stack monitoring
    wait_stack monitoring 300

    # ---- backup --------------------------------------------------------------
    deploy_stack backup
    wait_stack backup 300
    run_init minio-init
    ;;

  *)
    die "unknown target: ${TARGET} (expected: all, registry, ${STACK_ORDER[*]}, demo)"
    ;;
esac

prune_configs

section "Done"
docker stack ls
cat >&2 <<EOF

Next steps:
  make status      state of the nodes, services and clusters
  make smoke       end-to-end validation through the VIP (https://…${DOMAIN})
  make hosts       the /etc/hosts line for the client workstation
EOF

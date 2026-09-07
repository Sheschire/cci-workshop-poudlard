#!/usr/bin/env bash
# =============================================================================
# Validate every stack file with `docker stack config` (CDC §11.3).
#
# `docker stack config` parses the Compose file, substitutes the environment,
# resolves `extends`/anchors and rejects anything Swarm cannot deploy. It needs
# a Docker CLI but *no* daemon connection and no image pull, which is what makes
# it usable in CI.
#
# Beyond the parse, this script enforces the repository conventions of
# CDC §10.2 on the rendered output:
#   - every public image is pinned by tag AND digest;
#   - every service declares resource limits, a restart policy and a logging
#     driver;
#   - no service bind-mounts /var/run/docker.sock (CDC §6.4).
# =============================================================================
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

need_cmd docker
load_env

cd "$DW_ROOT"

# The Swarm-specific config keys (`configs`, `secrets`, `deploy`) require the
# stack context; `docker stack config` provides it.
mapfile -t STACK_FILES < <(find stacks -maxdepth 1 -name '*.yml' 2>/dev/null | sort)
# The repository is built phase by phase (CDC §13): before phase 1 there is no
# stack to validate yet. Report it rather than failing the CI.
if (( ${#STACK_FILES[@]} == 0 )); then
  warn "no stack file under stacks/ yet (phase 1 deliverable) — nothing to validate"
  exit 0
fi

rc=0
rendered_dir="$(mktemp -d)"
trap 'rm -rf "$rendered_dir"' EXIT

for stack in "${STACK_FILES[@]}"; do
  name="$(basename "$stack" .yml)"
  section "docker stack config — ${name}"
  if ! docker stack config --compose-file "$stack" > "${rendered_dir}/${name}.yml" 2>"${rendered_dir}/${name}.err"; then
    error "${stack} is invalid:"
    sed 's/^/    /' "${rendered_dir}/${name}.err" >&2
    rc=1
    continue
  fi
  ok "${stack} parses"

  # --- Convention checks on the rendered file --------------------------------
  # 1. Pinning. Home-made images live in the internal registry and are pinned
  #    by an immutable tag built by `make build`, not by digest (the digest is
  #    only known after the push) — they are exempt.
  while IFS= read -r image; do
    [[ "$image" == *"${REGISTRY}"* ]] && continue
    if [[ "$image" != *"@sha256:"* ]]; then
      error "${name}: image not pinned by digest: ${image}"
      rc=1
    fi
    if [[ "$image" != *:* || "$image" =~ ^[^:]+@sha256 ]]; then
      error "${name}: image pinned by digest but missing a readable tag: ${image}"
      rc=1
    fi
  done < <(grep -oE '^\s+image:\s*\S+' "${rendered_dir}/${name}.yml" | awk '{print $2}' | sort -u)

  # 2. No direct access to the Docker socket (CDC §6.4): only
  #    docker-socket-proxy may see it, and it does so through a bind mount that
  #    is declared in edge.yml with an explicit exception marker.
  if grep -qE '/var/run/docker\.sock' "${rendered_dir}/${name}.yml"; then
    if [[ "$name" != "edge" && "$name" != "backup" ]]; then
      error "${name}: a service mounts /var/run/docker.sock"
      rc=1
    fi
    # Even in edge/backup, only the socket proxies may do it.
    while IFS= read -r svc; do
      case "$svc" in
        docker-socket-proxy|docker-socket-proxy-rw) ;;
        *) error "${name}: service '${svc}' must not mount the Docker socket"; rc=1 ;;
      esac
    done < <(
      python3 - "${rendered_dir}/${name}.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for svc, spec in (doc.get("services") or {}).items():
    for vol in (spec.get("volumes") or []):
        src = vol.get("source") if isinstance(vol, dict) else str(vol).split(":")[0]
        if src and "docker.sock" in str(src):
            print(svc)
PY
    )
  fi

  # 3. Per-service hygiene required by CDC §10.2.
  python3 - "${rendered_dir}/${name}.yml" "$name" <<'PY' || rc=1
import sys, yaml
path, stack = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(path)) or {}
bad = []
for svc, spec in (doc.get("services") or {}).items():
    deploy = spec.get("deploy") or {}
    res = (deploy.get("resources") or {}).get("limits") or {}
    if not res:
        bad.append(f"{svc}: no deploy.resources.limits")
    if not deploy.get("restart_policy"):
        bad.append(f"{svc}: no deploy.restart_policy")
    if not spec.get("logging"):
        bad.append(f"{svc}: no logging driver")
for line in bad:
    print(f"    {stack}: {line}", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
  if (( rc == 0 )); then
    ok "${stack}: conventions respected"
  fi
done

section "Overrides"
# The single-node override is applied on top of every stack; validate the
# combination the way `make single` deploys it.
if [[ -f stacks/overrides/single-node.yml ]]; then
  for stack in "${STACK_FILES[@]}"; do
    name="$(basename "$stack" .yml)"
    [[ "$name" == "registry" ]] && continue
    if docker stack config -c "$stack" -c stacks/overrides/single-node.yml >/dev/null 2>&1; then
      ok "${name} + single-node override"
    else
      error "${name} + single-node override is invalid"
      docker stack config -c "$stack" -c stacks/overrides/single-node.yml 2>&1 | sed 's/^/    /' >&2
      rc=1
    fi
  done
fi

if (( rc == 0 )); then
  ok "every stack is valid"
else
  error "stack validation failed"
fi
exit "$rc"

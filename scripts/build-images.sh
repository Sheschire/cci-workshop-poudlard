#!/usr/bin/env bash
# =============================================================================
# `make build` — build the home-made images and push them to the internal
# registry (CDC §10.2).
#
#   scripts/build-images.sh                       build all four
#   scripts/build-images.sh alert2glpi            build one
#   scripts/build-images.sh --force alert2glpi    overwrite an existing tag
#
# Why a registry rather than a build on each node
# -----------------------------------------------
# The three nodes must run the SAME bits. Building the same Dockerfile on three
# machines cannot guarantee that: base layers, apt mirrors and build caches
# drift. One build, one push, three pulls of the same digest — and
# `docker service ps` proves it.
#
# `${IMAGE_TAG}` is treated as immutable: pushing over an existing tag needs
# `--force`. That is what lets the stacks reference the tag without a digest
# and still be reproducible.
# =============================================================================
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

need_docker
load_env

FORCE=0
[[ "${1:-}" == "--force" ]] && { FORCE=1; shift; }

readonly ALL_IMAGES=(cassandra alert2glpi backup-runner demo-producer)
IMAGES=("$@")
(( ${#IMAGES[@]} == 0 )) && IMAGES=("${ALL_IMAGES[@]}")

cd "$DW_ROOT"

# =============================================================================
# 1. The registry must exist before anything can be pushed.
# =============================================================================
section "Internal registry"
if docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null | grep -q true; then
  if ! docker service ls --format '{{.Name}}' | grep -q '^registry_registry$'; then
    info "the registry is not deployed — deploying stacks/registry.yml"
    "${DW_ROOT}/scripts/deploy.sh" registry
  fi
fi

# A build machine that cannot reach the registry would produce four images and
# fail on the first push: check once, up front, with a clear message.
if ! curl -sf --max-time 5 "http://${REGISTRY}/v2/" >/dev/null 2>&1; then
  warn "http://${REGISTRY}/v2/ is unreachable from this host."
  warn "Either run 'make build' from a cluster node, or add ${REGISTRY} to the"
  warn "'insecure-registries' of your workstation's daemon.json and open the route."
  die "registry unreachable"
fi
ok "registry ${REGISTRY} reachable"

# =============================================================================
# 2. Build and push
# =============================================================================
tag_exists() {
  local name=$1
  curl -sf --max-time 5 \
    "http://${REGISTRY}/v2/dockerwarts/${name}/tags/list" 2>/dev/null \
    | grep -q "\"${IMAGE_TAG}\""
}

built=0 skipped=0
for name in "${IMAGES[@]}"; do
  [[ -d "images/${name}" ]] || { warn "images/${name} does not exist yet — skipped"; continue; }

  # Each image builds from its own directory, except backup-runner: it copies
  # scripts/backup/*.sh into the image, and those live under scripts/ (CDC
  # §10.1), outside any images/ subdirectory. It therefore builds from the
  # repository root — which is exactly why the root carries a deny-by-default
  # .dockerignore: `secrets/`, `certs/` and `.env` must never enter a build
  # context, let alone an image layer pushed to the registry.
  context="images/${name}"
  dockerfile="images/${name}/Dockerfile"
  if [[ "$name" == "backup-runner" ]]; then
    context="."
  fi

  ref="${REGISTRY}/dockerwarts/${name}:${IMAGE_TAG}"
  section "${name} → ${ref}"

  if tag_exists "$name" && (( FORCE == 0 )); then
    warn "${ref} already exists. Bump IMAGE_TAG in .env, or pass --force."
    (( ++skipped ))
    continue
  fi

  # --pull: always re-resolve the base image, so a `FROM … @sha256:` that
  #   drifted is caught here rather than at runtime.
  # --provenance/--sbom false: the registry:2.8 API rejects the extra
  #   attestation manifests buildx attaches by default.
  docker buildx build \
    --pull \
    --provenance=false \
    --sbom=false \
    --file "$dockerfile" \
    --tag "$ref" \
    --label "org.opencontainers.image.title=dockerwarts/${name}" \
    --label "org.opencontainers.image.version=${IMAGE_TAG}" \
    --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --label "org.opencontainers.image.revision=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" \
    --load \
    "$context"

  docker push "$ref"
  digest="$(docker buildx imagetools inspect "$ref" 2>/dev/null | awk '/^Digest:/{print $2}')"
  ok "${ref}"
  log "   digest: ${digest:-unknown}"
  (( ++built ))
done

# =============================================================================
# 3. Summary
# =============================================================================
section "Summary"
ok "${built} image(s) built and pushed, ${skipped} skipped"

if (( built > 0 )); then
  cat >&2 <<EOF

The three nodes will pull ${IMAGE_TAG} on the next deployment.
To verify they all run the same content:
  docker service ps --no-trunc <service> | head -3
EOF
fi

#!/usr/bin/env bash
# =============================================================================
# Check (or refresh) the image digests pinned in stacks/ and images/.
#
#   scripts/pin-digests.sh            report drift only  (make pin-digests)
#   scripts/pin-digests.sh --write    rewrite the stacks with the current digests
#
# Why this exists
# ---------------
# CDC §6.4 requires every public image to be pinned by tag AND digest, and
# docs/04-composants/versions.md to be the register of record. A tag is mutable:
# `traefik:v3.7.13` can be rebuilt. This script re-resolves every tag and tells
# the operator when a pinned digest no longer matches — which is exactly when a
# deliberate, documented bump is due.
#
# It only reads manifests (no layer download), so it is cheap and works behind a
# registry mirror.
# =============================================================================
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

need_cmd docker
cd "$DW_ROOT"

WRITE=0
[[ "${1:-}" == "--write" ]] && WRITE=1

# Resolve the *index* digest of a tag (the multi-arch manifest list), which is
# what `image: name:tag@sha256:…` must carry.
resolve() {
  local ref=$1
  docker buildx imagetools inspect "$ref" 2>/dev/null \
    | awk '/^Digest:/{print $2; exit}'
}

mapfile -t FILES < <(find stacks images -type f \( -name '*.yml' -o -name 'Dockerfile' \) | sort)

declare -A SEEN=()
rc=0
drift=0

section "Verifying the pinned digests"
for file in "${FILES[@]}"; do
  # Matches both `image: repo:tag@sha256:…` in stacks and `FROM repo:tag@sha256:…`
  while IFS= read -r pinned; do
    local_ref="${pinned%@*}"
    local_digest="${pinned#*@}"

    # Home-made images live in the internal registry: their digest is only
    # known after `make build` pushes them, so they are pinned by tag.
    [[ "$local_ref" == *"dockerwarts/"* ]] && continue
    [[ -n "${SEEN[$pinned]:-}" ]] && continue
    SEEN[$pinned]=1

    current="$(resolve "$local_ref" || true)"
    if [[ -z "$current" ]]; then
      warn "${local_ref}: manifest unreachable (registry blocked or tag removed)"
      rc=1
      continue
    fi
    if [[ "$current" == "$local_digest" ]]; then
      ok "${local_ref}"
    else
      warn "${local_ref}: pinned ${local_digest:0:19}… → registry ${current:0:19}…"
      drift=1
      if (( WRITE )); then
        # `|` as the sed delimiter: the reference contains slashes.
        sed -i "s|${local_ref}@${local_digest}|${local_ref}@${current}|g" "$file"
        info "  rewritten in ${file}"
      fi
    fi
  done < <(grep -ohE '[A-Za-z0-9._/:-]+@sha256:[0-9a-f]{64}' "$file" | sort -u)
done

section "Result"
if (( drift == 0 && rc == 0 )); then
  ok "every pinned digest matches its tag"
elif (( WRITE )); then
  ok "digests refreshed — update docs/04-composants/versions.md and commit"
else
  warn "drift detected: run 'scripts/pin-digests.sh --write', then review the diff"
  warn "and record the new versions in docs/04-composants/versions.md"
  exit 1
fi
exit "$rc"

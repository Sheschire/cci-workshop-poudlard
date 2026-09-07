#!/usr/bin/env bash
# =============================================================================
# check-docs-coverage.sh — every configuration file is explained somewhere.
#
#   scripts/check-docs-coverage.sh            (part of `make lint`)
#
# CDC §12 asks that **each** file under config/ be documented, section by
# section, in docs/04-composants/. That is the kind of requirement that is true
# on the day it is written and quietly false three commits later: someone adds
# config/prometheus/rules/network.yml, and nothing anywhere notices.
#
# So it is checked. A file counts as documented when its path or its name
# appears in a documentation page — which is a weak test of *quality* and a
# strong test of *existence*: it cannot tell whether the explanation is good,
# but it catches the file nobody wrote a word about, which is the failure that
# actually happens.
#
# Also checked, in the other direction: a documentation page that references a
# configuration file which no longer exists. A runbook pointing at a deleted
# file is worse than no runbook.
# =============================================================================
set -Eeuo pipefail
# Paths are relative to --source-path=scripts (see the lint-shell target).
# shellcheck source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

cd "$DW_ROOT"

rc=0

# =============================================================================
# 1. Every config/ file is mentioned in the documentation
# =============================================================================
section "Fichiers de config/ documentés"

undocumented=()
total=0
while IFS= read -r file; do
  total=$(( total + 1 ))
  name="$(basename "$file")"
  # Either the full path (precise) or the bare file name (how a page usually
  # refers to it, e.g. "`galera.cnf` — section [galera]").
  if grep -rqlF -- "$file" docs/ 2>/dev/null; then continue; fi
  if grep -rqlF -- "$name" docs/ 2>/dev/null; then continue; fi
  undocumented+=("$file")
done < <(find config -type f | sort)

if (( ${#undocumented[@]} == 0 )); then
  ok "${total} fichiers sous config/, tous mentionnés dans docs/"
else
  error "${#undocumented[@]} fichier(s) de config/ ne sont mentionnés nulle part dans docs/ :"
  printf '    %s\n' "${undocumented[@]}" >&2
  error "  → CDC §12 : chaque fichier de config/ doit être expliqué dans docs/04-composants/"
  rc=1
fi

# =============================================================================
# 2. Every documented config/ path still exists
# =============================================================================
section "Références de la documentation vers config/"

dangling=()
while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  [[ -e "$ref" ]] && continue
  # Globs are legitimate in prose ("config/prometheus/rules/*.yml"); a glob
  # that matches nothing is a dangling reference, one that matches is fine.
  if [[ "$ref" == *"*"* ]]; then
    # shellcheck disable=SC2086  # deliberate glob expansion
    compgen -G $ref >/dev/null 2>&1 && continue
  fi
  dangling+=("$ref")
done < <(
  # `(^|[^/[:alnum:]])` anchors the match at the start of a path: without it,
  # a container-internal path such as
  # `/usr/share/elasticsearch/config/certs/node.key` matches its own tail and
  # is reported as a missing repository file.
  grep -rhoE '(^|[^/[:alnum:]_-])config/[A-Za-z0-9_./*-]+' docs/ 2>/dev/null \
    | sed -E 's#^[^c]*##; s/[.,;:)`]*$//' | sort -u
)

if (( ${#dangling[@]} == 0 )); then
  ok "aucune référence orpheline vers config/"
else
  error "${#dangling[@]} référence(s) de la documentation pointent vers un fichier absent :"
  printf '    %s\n' "${dangling[@]}" >&2
  rc=1
fi

# =============================================================================
# 3. Every component page referenced by the index exists, and vice versa
# =============================================================================
section "Pages de docs/04-composants/"

missing_index=()
while IFS= read -r page; do
  name="$(basename "$page")"
  [[ "$name" == "versions.md" ]] && continue
  if ! grep -rqlF "$name" docs/README.md docs/01-architecture.md README.md 2>/dev/null; then
    missing_index+=("$name")
  fi
done < <(find docs/04-composants -name '*.md' | sort)

if (( ${#missing_index[@]} == 0 )); then
  ok "chaque page de composant est référencée depuis une page d'index"
else
  # A warning and not an error: a component page that no index links to is
  # findable, just not discoverable. Worth saying, not worth failing a build.
  warn "${#missing_index[@]} page(s) ne sont référencées depuis aucun index :"
  printf '    %s\n' "${missing_index[@]}" >&2
fi

# =============================================================================
# 4. Every relative link in the documentation resolves
#
# A broken cross-reference is a small defect with a large cost: it is found by
# the person following it during an incident, which is the worst possible
# moment. Checked here rather than trusted, and cheap enough to run every time.
# =============================================================================
section "Liens internes"

if python3 - <<'PY'; then
import glob
import os
import re
import sys

broken = []
files = glob.glob("docs/**/*.md", recursive=True) + ["README.md"]
checked = 0
for path in files:
    base = os.path.dirname(path)
    with open(path, encoding="utf-8") as handle:
        content = handle.read()
    for match in re.finditer(r"\]\(([^)]+)\)", content):
        target = match.group(1).split("#")[0]
        if not target or target.startswith(("http://", "https://", "mailto:")):
            continue
        checked += 1
        if not os.path.exists(os.path.normpath(os.path.join(base, target))):
            broken.append(f"{path} → {target}")

for line in broken:
    print(f"    {line}", file=sys.stderr)
print(f"{checked} lien(s) relatif(s) vérifié(s)")
sys.exit(1 if broken else 0)
PY
  ok "tous les liens relatifs résolvent"
else
  error "des liens de la documentation pointent dans le vide"
  rc=1
fi

# =============================================================================
section "Résumé"
if (( rc == 0 )); then
  ok "documentation cohérente avec config/"
else
  error "la documentation ne couvre pas config/"
fi
exit "$rc"

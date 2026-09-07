#!/usr/bin/env bash
# =============================================================================
# Guard rail for CDC §N5: no secret may ever reach git.
#
# Run by `make lint` and by the CI `validate` job. It checks two things:
#   1. no file that must stay local is tracked by git (.env, secrets/, certs/,
#      private keys, the real Ansible inventory);
#   2. no obvious credential literal was pasted into a tracked file.
# =============================================================================
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

cd "$DW_ROOT"
rc=0

section "Tracked files that must not be committed"
# `git ls-files` only lists tracked files, so an ignored file is invisible here
# — which is exactly the desired outcome.
FORBIDDEN_PATTERNS=(
  '^\.env$'
  '^secrets/'
  '^certs/'
  '\.key$'
  '\.pem$'
  '^ansible/inventory/hosts\.yml$'
)
while IFS= read -r file; do
  for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
    if [[ "$file" =~ $pattern ]]; then
      error "tracked but must stay local: ${file}"
      rc=1
    fi
  done
done < <(git ls-files)
(( rc == 0 )) && ok "no forbidden file is tracked"

section "Credential literals in tracked files"
# Deliberately narrow: matches an assignment to a non-empty, non-placeholder
# value. Placeholders (changeme, CHANGE_ME, <…>, ${…}, _FILE indirections) are
# how the repository is meant to look.
PATTERN='(password|passwd|secret|token|api_?key|access_?key)[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9/+=_-]{12,}'
# Second filter, on the VALUE side. Without it the check produces false
# positives that are worse than useless — a scanner people learn to ignore is a
# scanner that will be ignored on the day it is right:
#   `= _read_secret("…")`  an assignment from a FUNCTION, not a literal. The
#                          giveaway is the `(` that follows.
#   `= "test-app-token"`   a fixture in a test file. Test doubles are not
#                          credentials, and tests/ is where they belong.
# Everything else still fails the build.
if git grep -nEI --ignore-case "$PATTERN" -- \
      ':!*.md' ':!docs/*' ':!scripts/check-no-secrets.sh' ':!.gitignore' \
  | grep -vEi 'changeme|change_me|example|placeholder|\$\{|\{\{|_FILE|xxxx|<[a-z_]+>|sha256:' \
  | grep -vE '[:=][[:space:]]*[A-Za-z_][A-Za-z0-9_.]*\(' \
  | grep -vE '^[^:]*/tests?/' ; then
  error "a credential literal may have been committed (see above)"
  rc=1
else
  ok "no credential literal found"
fi

exit "$rc"

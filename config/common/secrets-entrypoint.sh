#!/usr/bin/env bash
# =============================================================================
# Generic "Docker secret → environment variable" entrypoint.
#
# Mounted read-only as a Swarm config at /usr/local/bin/secrets-entrypoint.sh
# and used as the `entrypoint:` of every service whose image reads credentials
# from the environment but does NOT understand Docker secrets.
#
#   entrypoint: ["/usr/local/bin/secrets-entrypoint.sh", "<real entrypoint>"]
#
# Convention
# ----------
# For every environment variable named `<NAME>_FILE` **whose value points
# inside the secrets mount** (`/run/secrets/` by default, overridable with
# `SECRETS_DIR`), the referenced file is read and its content exported as
# `<NAME>`. The `_FILE` variable is then unset, so a child process cannot read
# the path either.
#
# The path restriction is not cosmetic. The environment of a normal container
# already contains variables like `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE` or
# `NODE_EXTRA_CA_CERTS` that end in `_FILE` and point at multi-kilobyte CA
# bundles. Converting those would export the whole bundle as a variable and
# blow past the exec argument limit — the container would fail to start with a
# completely unrelated error message.
#
# Why this exists at all
# ----------------------
# Putting a password directly in a Swarm `config` or in the service
# environment makes it readable with `docker config inspect` /
# `docker service inspect` from any manager, and it appears in the task JSON
# that the socket proxy would expose. A Docker *secret* is mounted as a file
# with restricted permissions and is never part of the service definition.
# This wrapper is the bridge for images that were not written with that in
# mind (Kibana, Fluent Bit, the Elasticsearch exporter…).
#
# Trade-off, stated plainly: the value does end up in the process environment
# of the target container, which is strictly weaker than a file. It is still
# markedly better than storing it in a config object, and it is the only option
# these images offer.
#
# Documented in docs/04-composants/kibana.md and fluent-bit.md.
# =============================================================================
set -Eeuo pipefail

log() { printf '[secrets-entrypoint] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

(( $# > 0 )) || die "usage: $0 <command> [args...]"

readonly SECRETS_DIR="${SECRETS_DIR:-/run/secrets}"

loaded=0
skipped=0
# `compgen -e` lists the exported environment, which is what a child process
# actually sees.
while IFS= read -r file_var; do
  [[ "$file_var" == *_FILE ]] || continue
  target="${file_var%_FILE}"
  path="${!file_var}"

  # An empty _FILE means "this optional secret is not configured": skip it
  # rather than fail, so the same wrapper serves optional credentials
  # (the off-site S3 keys, SMTP) and mandatory ones alike.
  [[ -n "$path" ]] || continue

  # Only paths inside the secrets mount are ours (see the header).
  if [[ "$path" != "${SECRETS_DIR}/"* ]]; then
    skipped=$(( skipped + 1 ))
    continue
  fi

  [[ -r "$path" ]] || die "${file_var}=${path} is not readable (secret not mounted?)"
  value="$(< "$path")"
  # An EMPTY secret is always a mistake — a mounted-but-empty file means the
  # generation step failed. Starting with an empty password would produce an
  # authentication loop that looks like a network problem.
  [[ -n "$value" ]] || die "${path} is empty — refusing to start"

  export "${target}=${value}"
  unset "$file_var"
  loaded=$(( loaded + 1 ))
done < <(compgen -e)

log "${loaded} secret(s) loaded from ${SECRETS_DIR} (${skipped} unrelated *_FILE variable(s) left alone)"

# `exec` so the real process becomes PID 1 and receives Swarm's SIGTERM
# directly: otherwise every update would end in SIGKILL after the grace period.
exec "$@"

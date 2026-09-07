#!/usr/bin/env bash
# =============================================================================
# MariaDB Galera — entrypoint wrapper (CDC §7.2).
#
# Mounted read-only as a Swarm config at /usr/local/bin/galera-entrypoint.sh
# and declared as the `entrypoint:` of galera-1/2/3.
#
# Why a wrapper is needed
# -----------------------
# 1. The three members share one configuration file but must each declare their
#    own `wsrep_node_name` / `wsrep_node_address`, and MariaDB does not expand
#    environment variables inside a .cnf file.
# 2. The initialisation SQL needs the application passwords, and the official
#    image runs `/docker-entrypoint-initdb.d/*.sql` through `mysql` verbatim —
#    no substitution there either.
# 3. Every credential must come from a Docker secret, never from the command
#    line (which is visible in `ps`) nor from the environment (visible in
#    `docker inspect`).
#
# It also implements the ONE-TIME bootstrap flag: GALERA_BOOTSTRAP=1 adds
# `--wsrep-new-cluster`, used by scripts/galera-bootstrap.sh and
# scripts/galera-recover.sh.
#
# Finally it hands over with `exec`, so mysqld becomes PID 1 and receives
# Swarm's SIGTERM directly. Without that, the wrapper would swallow the signal,
# every update would end in SIGKILL after the grace period, and each restart
# would trigger a full SST — the single most expensive Galera failure mode.
# =============================================================================
set -Eeuo pipefail

readonly TEMPLATE_DIR=/etc/mysql/templates
readonly CNF_TARGET=/etc/mysql/conf.d/galera.cnf
readonly INITDB_DIR=/docker-entrypoint-initdb.d
readonly INIT_TARGET="${INITDB_DIR}/10-dockerwarts.sql"

log() { printf '[galera-entrypoint] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# -----------------------------------------------------------------------------
# read_secret VAR — value of $VAR, or the contents of the file named by
# ${VAR}_FILE. The `_FILE` form is the one used in production: the value then
# never appears in the environment.
#
# An absent or empty value is FATAL, never an empty string. Without this guard,
# a secret that failed to mount would render
# `IDENTIFIED BY ''` and create a passwordless account reachable by every
# container on the `data` network — a silent, critical security regression.
# -----------------------------------------------------------------------------
read_secret() {
  local var="$1" file_var="${1}_FILE"
  local path="${!file_var:-}" value=""
  if [[ -n "$path" ]]; then
    [[ -r "$path" ]] || die "${file_var}=${path} is not readable (secret not mounted?)"
    value="$(< "$path")"
  else
    value="${!var:-}"
  fi
  [[ -n "$value" ]] || die "${var}(_FILE) is unset or empty — refusing to start"
  printf '%s' "$value"
}

# -----------------------------------------------------------------------------
# render SOURCE TARGET NAME=VALUE...
#
# Replaces every `${NAME}` by VALUE.
#
# Two traps this deliberately avoids:
#   * sed would treat `/`, `&` and `\` in the replacement as metacharacters —
#     a password containing any of them would be silently mangled. awk's
#     index/substr treats the value as opaque text.
#   * `awk -v val=…` ALSO processes backslash escapes, so a password containing
#     `\a` would arrive as a bell character. Values are therefore passed
#     through the environment and read with ENVIRON[], which does no escape
#     processing at all.
# -----------------------------------------------------------------------------
render() {
  local src="$1" dst="$2"; shift 2
  [[ -r "$src" ]] || die "${src} is missing (config not mounted?)"

  local tmp
  tmp="$(mktemp)"
  cp "$src" "$tmp"

  local pair name out
  for pair in "$@"; do
    name="${pair%%=*}"
    out="$(mktemp)"
    # Passed through the environment, scoped to this single awk invocation.
    DW_RENDER_PH="\${${name}}" DW_RENDER_VAL="${pair#*=}" \
      awk '
        BEGIN { ph = ENVIRON["DW_RENDER_PH"]; val = ENVIRON["DW_RENDER_VAL"] }
        {
          line = $0
          while ((i = index(line, ph)) > 0) {
            line = substr(line, 1, i - 1) val substr(line, i + length(ph))
          }
          print line
        }
      ' "$tmp" > "$out"
    mv "$out" "$tmp"
  done

  # Fail loudly rather than start a server with an unsubstituted placeholder:
  # `IDENTIFIED BY '${MARIADB_GLPI_PASSWORD}'` would otherwise create an
  # account whose password is that literal string.
  if grep -qE '\$\{[A-Z_]+\}' "$tmp"; then
    log "unsubstituted placeholders left in ${dst}:"
    grep -oE '\$\{[A-Z_]+\}' "$tmp" | sort -u | sed 's/^/    /' >&2
    rm -f "$tmp"
    die "incomplete rendering of ${src}"
  fi

  mv "$tmp" "$dst"
}

# =============================================================================
# 1. Secrets
# =============================================================================
SST_PW="$(read_secret MARIADB_SST_PASSWORD)"
[[ -n "$SST_PW" ]] || die "MARIADB_SST_PASSWORD(_FILE) is required"

: "${WSREP_NODE_NAME:?WSREP_NODE_NAME is required (galera-1|galera-2|galera-3)}"
: "${WSREP_NODE_ADDRESS:?WSREP_NODE_ADDRESS is required}"

# =============================================================================
# 2. Server configuration
# =============================================================================
render "${TEMPLATE_DIR}/galera.cnf.tpl" "$CNF_TARGET" \
  "WSREP_NODE_NAME=${WSREP_NODE_NAME}" \
  "WSREP_NODE_ADDRESS=${WSREP_NODE_ADDRESS}" \
  "MARIADB_SST_PASSWORD=${SST_PW}"

# The file holds the SST password: nobody but mysqld may read it.
chmod 640 "$CNF_TARGET"
chown root:mysql "$CNF_TARGET" 2>/dev/null || true
log "configuration rendered for ${WSREP_NODE_NAME} (${WSREP_NODE_ADDRESS})"

# --- Single-node profile ------------------------------------------------------
# `make single` runs one member. Synchronous replication no longer provides
# durability, so the local disk must: restore the fsync-per-commit that the
# cluster configuration deliberately trades away (see galera.cnf).
if [[ "${GALERA_SINGLE_NODE:-0}" == "1" ]]; then
  log "single-node profile: restoring innodb_flush_log_at_trx_commit=1"
  printf '\n[mysqld]\ninnodb_flush_log_at_trx_commit = 1\nsync_binlog = 1\n' >> "$CNF_TARGET"
fi

# =============================================================================
# 3. Initialisation SQL — first member only, first start only
#
# The image runs /docker-entrypoint-initdb.d/* only when the data directory is
# empty. Rendering the file on every member is harmless (members 2 and 3 arrive
# by SST, never through initdb) but pointless, so it is gated on the template
# being mounted — which stacks/data.yml only does for galera-1.
# =============================================================================
if [[ -r "${TEMPLATE_DIR}/init.sql.tpl" ]]; then
  # Each secret is read into its own variable FIRST, never inline in the
  # `render` call. `die` runs `exit`, and inside a `$( )` that only kills the
  # subshell: an inline read_secret would print its error and then hand an
  # EMPTY password to render, creating a passwordless account. As a plain
  # assignment, a failure propagates through `set -e` and stops the container.
  GLPI_PW="$(read_secret MARIADB_GLPI_PASSWORD)"
  GRAFANA_PW="$(read_secret MARIADB_GRAFANA_PASSWORD)"
  EXPORTER_PW="$(read_secret MARIADB_EXPORTER_PASSWORD)"
  BACKUP_PW="$(read_secret MARIADB_BACKUP_PASSWORD)"

  render "${TEMPLATE_DIR}/init.sql.tpl" "$INIT_TARGET" \
    "MARIADB_GLPI_PASSWORD=${GLPI_PW}" \
    "MARIADB_GRAFANA_PASSWORD=${GRAFANA_PW}" \
    "MARIADB_EXPORTER_PASSWORD=${EXPORTER_PW}" \
    "MARIADB_BACKUP_PASSWORD=${BACKUP_PW}" \
    "MARIADB_SST_PASSWORD=${SST_PW}"
  chmod 600 "$INIT_TARGET"
  log "initialisation SQL rendered"
fi

# =============================================================================
# 4. Bootstrap flag
#
# Set ONLY by scripts/galera-bootstrap.sh (first start) and by
# scripts/galera-recover.sh (recovery after a full cluster stop). Starting two
# members with this flag at the same time creates two independent clusters that
# both believe they are authoritative — the classic Galera split-brain, which
# no amount of later repair fixes cleanly.
# =============================================================================
declare -a extra=()
if [[ "${GALERA_BOOTSTRAP:-0}" == "1" ]]; then
  log "GALERA_BOOTSTRAP=1 → starting with --wsrep-new-cluster"
  log "  this must hold on EXACTLY ONE member; see docs/04-composants/galera.md"
  extra+=(--wsrep-new-cluster)
fi

# =============================================================================
# 5. Hand over
# =============================================================================
exec docker-entrypoint.sh mariadbd "$@" "${extra[@]}"

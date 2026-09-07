#!/usr/bin/env bash
# =============================================================================
# Dockerwarts N°1 — shared shell helpers.
#
# Sourced (never executed) by every script under scripts/ and tests/:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# Provides: logging, fatal errors, .env loading, Docker/Swarm guards,
# wait helpers and a Markdown report writer.
# =============================================================================

# Guard against double sourcing (deploy.sh sources it, then calls a script that
# sources it again through `set -a`).
[[ -n "${DW_COMMON_SOURCED:-}" ]] && return 0
readonly DW_COMMON_SOURCED=1

# --- Paths -------------------------------------------------------------------
DW_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DW_ROOT="$(cd -- "${DW_LIB_DIR}/../.." && pwd)"
readonly DW_LIB_DIR DW_ROOT
readonly DW_ENV_FILE="${DW_ROOT}/.env"
readonly DW_REPORTS_DIR="${DW_ROOT}/reports"
# Exported: consumed by init-secrets.sh, gen-certs.sh and the restore scripts.
DW_SECRETS_DIR="${DW_ROOT}/secrets"
DW_CERTS_DIR="${DW_ROOT}/certs"
export DW_SECRETS_DIR DW_CERTS_DIR

# --- Colours (disabled when the output is not a terminal) --------------------
if [[ -t 2 ]]; then
  DW_C_RESET=$'\033[0m'; DW_C_RED=$'\033[31m'; DW_C_GREEN=$'\033[32m'
  DW_C_YELLOW=$'\033[33m'; DW_C_BLUE=$'\033[34m'; DW_C_DIM=$'\033[2m'
else
  DW_C_RESET=''; DW_C_RED=''; DW_C_GREEN=''; DW_C_YELLOW=''; DW_C_BLUE=''; DW_C_DIM=''
fi
readonly DW_C_RESET DW_C_RED DW_C_GREEN DW_C_YELLOW DW_C_BLUE DW_C_DIM

# --- Logging -----------------------------------------------------------------
_dw_ts() { date -u '+%H:%M:%S'; }

log()   { printf '%s[%s]%s %s\n'      "$DW_C_DIM"    "$(_dw_ts)" "$DW_C_RESET" "$*" >&2; }
info()  { printf '%s[%s] ▸%s %s\n'    "$DW_C_BLUE"   "$(_dw_ts)" "$DW_C_RESET" "$*" >&2; }
ok()    { printf '%s[%s] ✔%s %s\n'    "$DW_C_GREEN"  "$(_dw_ts)" "$DW_C_RESET" "$*" >&2; }
warn()  { printf '%s[%s] ⚠%s %s\n'    "$DW_C_YELLOW" "$(_dw_ts)" "$DW_C_RESET" "$*" >&2; }
error() { printf '%s[%s] ✘%s %s\n'    "$DW_C_RED"    "$(_dw_ts)" "$DW_C_RESET" "$*" >&2; }
die()   { error "$*"; exit 1; }

# Section header, used by the long-running scripts.
section() {
  printf '\n%s══ %s %s%s\n' "$DW_C_BLUE" "$*" \
    "$(printf '═%.0s' $(seq 1 $(( 60 - ${#1} > 0 ? 60 - ${#1} : 0 ))))" "$DW_C_RESET" >&2
}

# Print a stack trace on unexpected failures — every script sets -E, so the ERR
# trap is inherited by functions and subshells.
dw_on_error() {
  local rc=$? line=${1:-?} cmd=${2:-?}
  error "command failed (rc=${rc}) at line ${line}: ${cmd}"
  exit "$rc"
}
trap 'dw_on_error "$LINENO" "$BASH_COMMAND"' ERR

# --- Environment -------------------------------------------------------------
# Load .env into the environment so that `docker stack deploy` can substitute
# ${VAR} in the stack files (CDC §10.2).
load_env() {
  local file="${1:-$DW_ENV_FILE}"
  [[ -f "$file" ]] || die ".env is missing. Run: cp .env.example .env"
  set -a
  # shellcheck disable=SC1090  # runtime path, by design
  source "$file"
  set +a

  : "${DOMAIN:?DOMAIN must be set in .env}"
  : "${VIP:?VIP must be set in .env}"
  : "${REGISTRY:?REGISTRY must be set in .env}"
  : "${PROFILE:=full}"
  : "${IMAGE_TAG:=1.0.0}"
  : "${TZ:=Europe/Paris}"
  : "${NFS_SERVER:?NFS_SERVER must be set in .env}"
  : "${CLUSTER_CIDR:?CLUSTER_CIDR must be set in .env}"
  : "${ADMIN_CIDR:?ADMIN_CIDR must be set in .env}"
  : "${DATA_NETWORK_ENCRYPTED:=true}"
  export DOMAIN VIP REGISTRY PROFILE IMAGE_TAG TZ NFS_SERVER
  export CLUSTER_CIDR ADMIN_CIDR DATA_NETWORK_ENCRYPTED

  # Derived JVM sizing (CDC §3.1): a single knob drives every heap.
  if [[ "$PROFILE" == "lite" ]]; then
    export ES_HEAP="512m" CASSANDRA_HEAP="768M" CASSANDRA_NEWSIZE="192M"
  else
    export ES_HEAP="1g" CASSANDRA_HEAP="1G" CASSANDRA_NEWSIZE="256M"
  fi
}

# --- Guards ------------------------------------------------------------------
need_cmd() {
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  (( ${#missing[@]} == 0 )) || die "missing command(s): ${missing[*]}"
}

need_docker() {
  need_cmd docker
  docker info >/dev/null 2>&1 || die "the Docker daemon is unreachable"
}

need_swarm() {
  need_docker
  local state
  state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo inactive)"
  [[ "$state" == "active" ]] || die "this host is not part of a Swarm (state: ${state})"
}

need_manager() {
  need_swarm
  [[ "$(docker info --format '{{.Swarm.ControlAvailable}}')" == "true" ]] \
    || die "this command must run on a Swarm manager"
}

# --- Wait helpers ------------------------------------------------------------
# retry <attempts> <delay_seconds> <command...>
retry() {
  local attempts=$1 delay=$2; shift 2
  local n=1
  until "$@"; do
    (( n >= attempts )) && return 1
    sleep "$delay"
    (( n++ ))
  done
  return 0
}

# Wait until a Swarm service has all of its desired replicas running.
# wait_service <service> [timeout_seconds]
wait_service() {
  local svc=$1 timeout=${2:-180} elapsed=0 running desired
  info "waiting for ${svc} …"
  while (( elapsed < timeout )); do
    read -r running desired < <(
      docker service ls --filter "name=${svc}" \
        --format '{{.Replicas}}' | head -1 | tr '/' ' '
    ) || true
    if [[ -n "${running:-}" && -n "${desired:-}" && "$running" == "$desired" && "$running" != "0" ]]; then
      ok "${svc}: ${running}/${desired} replicas"
      return 0
    fi
    sleep 3
    elapsed=$(( elapsed + 3 ))
  done
  error "${svc}: ${running:-0}/${desired:-?} after ${timeout}s"
  docker service ps --no-trunc "$svc" 2>&1 | head -20 >&2 || true
  return 1
}

# Run a command inside a running task of a Swarm service, on this node or any
# other, without needing to know where it landed.
# svc_exec <service> <command...>
svc_exec() {
  local svc=$1; shift
  local cid
  cid="$(docker ps -q --filter "label=com.docker.swarm.service.name=${svc}" | head -1)"
  [[ -n "$cid" ]] || die "no local task of ${svc} on $(hostname); run this from the right node"
  docker exec "$cid" "$@"
}

# --- Reports -----------------------------------------------------------------
# Every test script writes a Markdown report that the documentation quotes.
report_init() {
  local name=$1 title=$2
  mkdir -p "$DW_REPORTS_DIR"
  DW_REPORT="${DW_REPORTS_DIR}/${name}-$(date -u '+%Y%m%dT%H%M%SZ').md"
  export DW_REPORT
  {
    printf '# %s\n\n' "$title"
    printf -- '- **Date (UTC)** : %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
    printf -- '- **Hôte**       : %s\n' "$(hostname)"
    printf -- '- **Profil**     : %s\n\n' "${PROFILE:-?}"
  } > "$DW_REPORT"
  info "report: ${DW_REPORT}"
}

report() { printf '%s\n' "$*" >> "$DW_REPORT"; }

# Track pass/fail counts across a whole test run.
DW_PASS=0
DW_FAIL=0
check() {
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then
    ok "$label"; (( ++DW_PASS ))
    [[ -n "${DW_REPORT:-}" ]] && report "| ✅ | ${label} | — |"
    return 0
  fi
  error "$label"; (( ++DW_FAIL ))
  [[ -n "${DW_REPORT:-}" ]] && report "| ❌ | ${label} | échec |"
  return 1
}

summary() {
  printf '\n' >&2
  if (( DW_FAIL == 0 )); then
    ok "${DW_PASS} checks passed, 0 failed"
    return 0
  fi
  error "${DW_PASS} checks passed, ${DW_FAIL} FAILED"
  return 1
}

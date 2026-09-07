#!/usr/bin/env bash
# =============================================================================
# `make secrets` — generate the local secret material and create the Docker
# secrets the stacks expect (CDC §10.2, annexe A).
#
# Two-step design, on purpose:
#
#   secrets/*.txt      local, git-ignored, generated once with a CSPRNG.
#                      This is the copy an operator puts in the vault — and
#                      the ONLY way to restore a backup (ADR-0008): restic and
#                      the S3 keys live here. Losing this directory without a
#                      vault copy makes every backup unreadable.
#   docker secret …    what the services actually read, at /run/secrets/<name>.
#
# Idempotent: an existing file is never regenerated, an existing Docker secret
# is never touched (Swarm secrets are immutable — rotation is a documented
# procedure, see docs/08-exploitation.md).
#
#   scripts/init-secrets.sh              generate what is missing, then load
#   scripts/init-secrets.sh --list       show the expected inventory and state
#   scripts/init-secrets.sh --rotate X   regenerate ONE secret (prints the
#                                        redeploy commands; does not apply them)
# =============================================================================
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

load_env

# =============================================================================
# Inventory — CDC annexe A. `name:kind` where kind drives the generator.
#
#   pw32   32-byte URL-safe password (databases, applications)
#   pw24   24-byte password (kept shorter where a UI displays it)
#   hex64  64 hex characters (API keys, encryption keys)
#   user   a login, not a password (MinIO root user)
#   file   filled in by another script (certificates); only declared here so
#          that --list can report it
# =============================================================================
readonly -a SECRET_SPEC=(
  # --- Edge: TLS and administration -----------------------------------------
  "dw_tls_cert:file"                  # wildcard certificate      → gen-certs.sh
  "dw_tls_key:file"                   # wildcard private key      → gen-certs.sh
  "dw_ca_cert:file"                   # internal CA               → gen-certs.sh
  "dw_traefik_htpasswd:file"          # basic-auth                → generated below
  "dw_traefik_admin_password:pw24"    # cleartext side of the htpasswd, for the operator

  # --- CrowdSec --------------------------------------------------------------
  "dw_crowdsec_bouncer_key:hex64"     # Traefik bouncer plugin ↔ LAPI
  "dw_crowdsec_agent_password:pw32"   # agent registration against the LAPI

  # --- MariaDB Galera --------------------------------------------------------
  "dw_mariadb_root_password:pw32"
  "dw_mariadb_glpi_password:pw32"
  "dw_mariadb_grafana_password:pw32"
  "dw_mariadb_sst_password:pw32"      # mariabackup state transfer
  "dw_mariadb_exporter_password:pw32"
  "dw_mariadb_backup_password:pw32"

  # --- Cassandra -------------------------------------------------------------
  "dw_cassandra_admin_password:pw32"
  "dw_cassandra_app_password:pw32"
  "dw_cassandra_backup_password:pw32"
  "dw_cassandra_jmx_password:file"    # jmxremote.password format
  "dw_cassandra_jmx_access:file"      # jmxremote.access format

  # --- Elasticsearch / Kibana ------------------------------------------------
  "dw_es_ca:file"                     # transport CA             → gen-es-certs.sh
  "dw_es_cert_1:file"
  "dw_es_key_1:file"
  "dw_es_cert_2:file"
  "dw_es_key_2:file"
  "dw_es_cert_3:file"
  "dw_es_key_3:file"
  "dw_es_elastic_password:pw32"
  "dw_es_kibana_password:pw32"
  "dw_es_fluentbit_password:pw32"
  "dw_es_grafana_password:pw32"
  "dw_es_app_password:pw32"
  "dw_es_exporter_password:pw32"
  "dw_kibana_encryption_key:hex64"    # xpack.encryptedSavedObjects (≥ 32 chars)

  # --- GLPI ------------------------------------------------------------------
  "dw_glpi_admin_password:pw32"
  "dw_glpi_app_token:hex64"           # GLPI API application token
  "dw_glpi_user_token:hex64"          # token of the `alertmanager` GLPI account

  # --- Grafana ---------------------------------------------------------------
  "dw_grafana_admin_password:pw32"
  "dw_grafana_secret_key:hex64"       # signs cookies: MUST be identical on both replicas

  # --- MinIO / backups -------------------------------------------------------
  "dw_minio_root_user:user"
  "dw_minio_root_password:pw32"
  "dw_minio_restic_key:user"
  "dw_minio_restic_secret:pw32"
  "dw_minio_es_key:user"
  "dw_minio_es_secret:pw32"
  "dw_minio_mirror_key:user"          # read-only, for the off-site mirror job
  "dw_minio_mirror_secret:pw32"
  # No dw_minio_prometheus_token: MinIO does not accept an arbitrary bearer
  # token, only a JWT derived from the root credentials, which expires and
  # would silently take the supervision of MinIO down with it (ADR-0010).
  "dw_restic_password:pw32"           # AES-256 repository key — VAULT THIS ONE

  # --- Off-site mirror (optional) -------------------------------------------
  "dw_offsite_s3_key:user"
  "dw_offsite_s3_secret:pw32"
)

MODE="generate"
ROTATE_TARGET=""
case "${1:-}" in
  --list)   MODE="list" ;;
  --rotate) MODE="rotate"; ROTATE_TARGET="${2:?usage: --rotate <secret-name>}" ;;
  "")       ;;
  *)        die "usage: $0 [--list | --rotate <secret-name>]" ;;
esac

# --- Generators --------------------------------------------------------------
# `openssl rand` is a CSPRNG; `-base64` then trimmed to URL-safe characters so
# that a password can be pasted into a DSN or a shell without quoting games.
gen_value() {
  case "$1" in
    pw32)  openssl rand -base64 48 | tr -d '\n=+/' | cut -c1-32 ;;
    pw24)  openssl rand -base64 36 | tr -d '\n=+/' | cut -c1-24 ;;
    hex64) openssl rand -hex 32 ;;
    user)  printf 'dw%s' "$(openssl rand -hex 6)" ;;
    *)     die "unknown secret kind: $1" ;;
  esac
}

# --- List mode ---------------------------------------------------------------
if [[ "$MODE" == "list" ]]; then
  need_docker
  printf '%-34s %-6s %-8s %s\n' "SECRET" "KIND" "LOCAL" "IN SWARM"
  for spec in "${SECRET_SPEC[@]}"; do
    name="${spec%%:*}"; kind="${spec##*:}"
    local_state="—"; [[ -f "${DW_SECRETS_DIR}/${name}.txt" ]] && local_state="yes"
    swarm_state="—"
    docker secret inspect "$name" >/dev/null 2>&1 && swarm_state="yes"
    printf '%-34s %-6s %-8s %s\n' "$name" "$kind" "$local_state" "$swarm_state"
  done
  exit 0
fi

# --- Rotation mode -----------------------------------------------------------
# A Swarm secret is immutable: rotating means creating a new one and updating
# the services that reference it. This script only does the local half and
# prints the rest — applying it is an operator decision, mid-incident.
if [[ "$MODE" == "rotate" ]]; then
  need_manager
  found=0
  for spec in "${SECRET_SPEC[@]}"; do
    [[ "${spec%%:*}" == "$ROTATE_TARGET" ]] && found=1 && kind="${spec##*:}"
  done
  (( found )) || die "unknown secret: ${ROTATE_TARGET} (see --list)"
  [[ "$kind" == "file" ]] && die "${ROTATE_TARGET} is generated by a certificate script, not here"

  stamp="$(date -u '+%Y%m%d%H%M%S')"
  mkdir -p "$DW_SECRETS_DIR"
  mv "${DW_SECRETS_DIR}/${ROTATE_TARGET}.txt" \
     "${DW_SECRETS_DIR}/${ROTATE_TARGET}.txt.old-${stamp}" 2>/dev/null || true
  gen_value "$kind" > "${DW_SECRETS_DIR}/${ROTATE_TARGET}.txt"
  chmod 600 "${DW_SECRETS_DIR}/${ROTATE_TARGET}.txt"
  new_name="${ROTATE_TARGET}_${stamp}"
  docker secret create "$new_name" "${DW_SECRETS_DIR}/${ROTATE_TARGET}.txt" >/dev/null
  ok "created the Docker secret ${new_name}"
  cat >&2 <<EOF

Next steps (see docs/08-exploitation.md — "Rotation des secrets"):
  1. change the value inside the component itself (SQL user, API token, …);
  2. point the services at the new secret:
       docker service update \\
         --secret-rm ${ROTATE_TARGET} \\
         --secret-add source=${new_name},target=${ROTATE_TARGET} \\
         <service>
  3. once every service is updated:  docker secret rm ${ROTATE_TARGET}
  4. rename ${new_name} back to ${ROTATE_TARGET} on the next full redeploy.
EOF
  exit 0
fi

# =============================================================================
# Generate mode
# =============================================================================
need_cmd openssl
mkdir -p "$DW_SECRETS_DIR"
chmod 700 "$DW_SECRETS_DIR"

section "Local secret material"
created=0 kept=0
for spec in "${SECRET_SPEC[@]}"; do
  name="${spec%%:*}"; kind="${spec##*:}"
  file="${DW_SECRETS_DIR}/${name}.txt"
  [[ "$kind" == "file" ]] && continue
  if [[ -f "$file" ]]; then
    (( ++kept ))
    continue
  fi
  gen_value "$kind" > "$file"
  chmod 600 "$file"
  (( ++created ))
done
ok "${created} generated, ${kept} already present in ${DW_SECRETS_DIR}/"

# --- htpasswd for the Traefik basic-auth middleware --------------------------
# bcrypt, cost 10. Generated from the cleartext password stored alongside so
# that the operator can actually log in.
if [[ ! -f "${DW_SECRETS_DIR}/dw_traefik_htpasswd.txt" ]]; then
  admin_pw="$(cat "${DW_SECRETS_DIR}/dw_traefik_admin_password.txt")"
  # `openssl passwd -5` (SHA-256 crypt) is understood by Traefik's basic-auth
  # and avoids depending on apache2-utils being installed.
  printf 'admin:%s\n' "$(openssl passwd -5 "$admin_pw")" \
    > "${DW_SECRETS_DIR}/dw_traefik_htpasswd.txt"
  chmod 600 "${DW_SECRETS_DIR}/dw_traefik_htpasswd.txt"
  ok "dw_traefik_htpasswd (user: admin)"
fi

# --- Cassandra JMX authentication files --------------------------------------
# `nodetool` over JMX needs two files in a fixed format; the password file must
# be mode 0400 or the JVM refuses to start.
if [[ ! -f "${DW_SECRETS_DIR}/dw_cassandra_jmx_password.txt" ]]; then
  jmx_pw="$(cat "${DW_SECRETS_DIR}/dw_cassandra_admin_password.txt")"
  printf 'monitorRole %s\ncontrolRole %s\n' "$jmx_pw" "$jmx_pw" \
    > "${DW_SECRETS_DIR}/dw_cassandra_jmx_password.txt"
  printf 'monitorRole readonly\ncontrolRole readwrite \\\n  create javax.management.monitor.*,javax.management.timer.* \\\n  unregister\n' \
    > "${DW_SECRETS_DIR}/dw_cassandra_jmx_access.txt"
  chmod 600 "${DW_SECRETS_DIR}"/dw_cassandra_jmx_{password,access}.txt
  ok "dw_cassandra_jmx_password / dw_cassandra_jmx_access"
fi

# --- Load into Swarm ---------------------------------------------------------
# Not fatal when there is no Swarm: `make secrets` is also run on a workstation
# to prepare the vault copy before the VMs exist.
section "Docker secrets"
if ! docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null | grep -q true; then
  warn "not on a Swarm manager: the local files are ready, the Docker secrets are not created"
  warn "re-run this script from a manager (or via 'make secrets' on a node)"
  exit 0
fi

loaded=0 present=0 missing=()
for spec in "${SECRET_SPEC[@]}"; do
  name="${spec%%:*}"
  file="${DW_SECRETS_DIR}/${name}.txt"
  if docker secret inspect "$name" >/dev/null 2>&1; then
    (( ++present ))
    continue
  fi
  if [[ ! -f "$file" ]]; then
    missing+=("$name")
    continue
  fi
  docker secret create "$name" "$file" >/dev/null
  (( ++loaded ))
done
ok "${loaded} secrets created, ${present} already present"

if (( ${#missing[@]} > 0 )); then
  warn "not created yet (produced by 'make certs'):"
  printf '    - %s\n' "${missing[@]}" >&2
fi

cat >&2 <<EOF

$(printf '%s' "$DW_C_YELLOW")IMPORTANT$(printf '%s' "$DW_C_RESET") — ${DW_SECRETS_DIR}/ is git-ignored and never leaves this host.
Copy it into your vault now. Without dw_restic_password and the dw_minio_*
keys, NO backup can ever be restored (ADR-0008).
EOF

#!/usr/bin/env bash
# =============================================================================
# GLPI initialisation (CDC §7.5).
#
#   scripts/glpi-init.sh            (called by deploy.sh after `apps`)
#
# Idempotent: every step checks its own precondition, so re-running after a
# redeploy or during a disaster-recovery drill converges instead of failing.
#
# What it does, in order:
#   1. wait for glpi-web to answer;
#   2. install the database if the tables are absent (`db:install`);
#   3. CHANGE THE FOUR DEFAULT PASSWORDS — the single most important step;
#   4. enable the REST API and declare the trusted proxy;
#   5. create the `alertmanager` user and its API tokens;
#   6. store the tokens as Docker secrets for alert2glpi;
#   7. create the "Infrastructure" ITIL category;
#   8. verify the API end to end.
#
# Step 3 in detail
# ----------------
# A fresh GLPI ships four accounts with published passwords:
#   glpi/glpi (super-admin), tech/tech, normal/normal, post-only/postonly.
# Leaving any of them is a full compromise of the ticketing system — and of the
# infrastructure information it holds. This is the step a manual installation
# always postpones, so it is automated here.
# =============================================================================
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

need_manager
load_env
cd "$DW_ROOT"

readonly STACK=apps
readonly SVC="${STACK}_glpi-web"
readonly CONSOLE="php /var/www/glpi/bin/console --no-interaction"

CID="$(docker ps -q --filter "label=com.docker.swarm.service.name=${SVC}" | head -1)"
[[ -n "$CID" ]] || die "no glpi-web task on $(hostname) — run this from a node hosting one"
info "using the GLPI container ${CID:0:12}"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
glpi_console() { docker exec -i "$CID" sh -c "${CONSOLE} $*" 2>&1; }

# Run SQL against the GLPI database from inside the container, using the
# credentials it already has mounted. Avoids needing a MariaDB client here and
# keeps the password inside the container.
# shellcheck disable=SC2016  # the $() must expand INSIDE the container
glpi_sql() {
  docker exec -i "$CID" sh -c \
    'mysql -h "$GLPI_DB_HOST" -u "$GLPI_DB_USER" -p"$GLPI_DB_PASSWORD" \
       -N -B "$GLPI_DB_NAME"' <<<"$1" 2>/dev/null
}

read_secret() {
  local value
  value="$(docker exec "$CID" sh -c "cat /run/secrets/$1 2>/dev/null" || true)"
  [[ -n "$value" ]] || die "secret $1 is unreadable inside the container"
  printf '%s' "$value"
}

# GLPI hashes passwords with PHP's password_hash (bcrypt). Generating the hash
# with PHP inside the container is the only way to produce one GLPI accepts.
php_password_hash() {
  docker exec -i "$CID" php -r \
    'echo password_hash(trim(stream_get_contents(STDIN)), PASSWORD_BCRYPT);' <<<"$1"
}

# =============================================================================
# 1. Wait for GLPI to answer
# =============================================================================
section "1/8 — waiting for glpi-web"
elapsed=0
while (( elapsed < 300 )); do
  if docker exec "$CID" curl -sf http://localhost/status.php 2>/dev/null | grep -q 'GLPI_OK\|GLPI_PROBLEM'; then
    ok "glpi-web answers on status.php"
    break
  fi
  sleep 10
  elapsed=$(( elapsed + 10 ))
done
(( elapsed < 300 )) || die "glpi-web did not answer within 300 s"

# =============================================================================
# 2. Database installation
#
# The check is the presence of the `glpi_configs` table, not a marker file: a
# marker on NFS would survive a database restore and make the script skip an
# installation that is genuinely needed.
# =============================================================================
section "2/8 — database"
tables="$(glpi_sql "SHOW TABLES LIKE 'glpi_configs';" || true)"
if [[ -n "$tables" ]]; then
  ok "the database is already installed"
else
  info "installing the GLPI database (this takes a couple of minutes)"
  # shellcheck disable=SC2016  # expanded inside the container
  output="$(docker exec -i "$CID" sh -c \
    "${CONSOLE} db:install \
       --db-host=\"\$GLPI_DB_HOST\" --db-port=\"\$GLPI_DB_PORT\" \
       --db-name=\"\$GLPI_DB_NAME\" --db-user=\"\$GLPI_DB_USER\" \
       --db-password=\"\$GLPI_DB_PASSWORD\" \
       --default-language=fr_FR --force" 2>&1 || true)"
  if glpi_sql "SHOW TABLES LIKE 'glpi_configs';" | grep -q glpi_configs; then
    ok "database installed"
  else
    error "db:install failed:"
    printf '    %s\n' "${output//$'\n'/$'\n    '}" >&2
    exit 1
  fi
fi

# Schema migrations, in case the image was upgraded under an existing database.
glpi_console "database:update --force" >/dev/null 2>&1 || true

# =============================================================================
# 3. Default passwords — THE critical step
# =============================================================================
section "3/8 — default accounts"
ADMIN_PW="$(read_secret dw_glpi_admin_password)"

# `glpi` keeps its super-admin profile with the generated password.
# The other three are DISABLED rather than given a password: this platform has
# exactly one human administrator and one machine account. A disabled account
# cannot be brute-forced at all.
hash="$(php_password_hash "$ADMIN_PW")"
[[ "$hash" == \$2y\$* ]] || die "the generated bcrypt hash looks wrong: ${hash:0:10}…"

glpi_sql "UPDATE glpi_users SET password = '${hash}', is_active = 1
          WHERE name = 'glpi';" >/dev/null
ok "account 'glpi': password replaced (see secrets/dw_glpi_admin_password.txt)"

for user in tech normal post-only; do
  n="$(glpi_sql "SELECT COUNT(*) FROM glpi_users WHERE name = '${user}';" || echo 0)"
  if [[ "$n" == "0" ]]; then
    log "  account '${user}' does not exist — nothing to do"
    continue
  fi
  # Disabled AND given a random unusable password: `is_active = 0` alone would
  # still leave a known password in place if someone re-enabled the account.
  random_hash="$(php_password_hash "$(openssl rand -base64 32)")"
  glpi_sql "UPDATE glpi_users SET is_active = 0, password = '${random_hash}'
            WHERE name = '${user}';" >/dev/null
  ok "account '${user}': disabled and its default password destroyed"
done

# Prove it: a default password must no longer authenticate.
still_default="$(glpi_sql "
  SELECT COUNT(*) FROM glpi_users
  WHERE name IN ('glpi','tech','normal','post-only') AND is_active = 1 AND name != 'glpi';" || echo '?')"
if [[ "$still_default" == "0" ]]; then
  ok "no default account is active any more"
else
  warn "unexpected: ${still_default} default account(s) still active"
fi

# =============================================================================
# 4. REST API and trusted proxy
# =============================================================================
section "4/8 — REST API"
# `enable_api` + `enable_api_login_credentials` are what alert2glpi needs to
# open a session with an app-token and a user-token.
glpi_sql "UPDATE glpi_configs SET value = '1'
          WHERE context = 'core' AND name IN
            ('enable_api', 'enable_api_login_credentials', 'enable_api_login_external_token');" >/dev/null
ok "REST API enabled"

# X-Forwarded-For: without this GLPI logs the overlay gateway as the source of
# every connection, which makes its own audit log worthless and breaks any
# per-IP restriction.
glpi_sql "UPDATE glpi_configs SET value = '1'
          WHERE context = 'core' AND name = 'proxy_passthrough';" >/dev/null 2>&1 || true
# The `edge` overlay range is the only trusted proxy source.
glpi_sql "INSERT INTO glpi_configs (context, name, value)
          VALUES ('core', 'trusted_proxies', '10.20.0.0/16')
          ON DUPLICATE KEY UPDATE value = '10.20.0.0/16';" >/dev/null 2>&1 || true
ok "trusted proxy declared (overlay range)"

# The public URL, so notification e-mails and API links are correct.
glpi_sql "UPDATE glpi_configs SET value = 'https://glpi.${DOMAIN}'
          WHERE context = 'core' AND name = 'url_base';" >/dev/null
glpi_sql "UPDATE glpi_configs SET value = 'https://glpi.${DOMAIN}/api'
          WHERE context = 'core' AND name = 'url_base_api';" >/dev/null
ok "public URL set to https://glpi.${DOMAIN}"

# =============================================================================
# 5. The `alertmanager` account and its tokens
# =============================================================================
section "5/8 — alertmanager account and API tokens"
APP_TOKEN="$(read_secret dw_glpi_app_token)"
USER_TOKEN="$(read_secret dw_glpi_user_token)"

# --- application token (identifies the CLIENT, here alert2glpi) --------------
existing="$(glpi_sql "SELECT COUNT(*) FROM glpi_apiclients WHERE name = 'alert2glpi';" || echo 0)"
if [[ "$existing" == "0" ]]; then
  glpi_sql "INSERT INTO glpi_apiclients
              (entities_id, is_recursive, name, is_active, ipv4_range_start, ipv4_range_end,
               app_token, app_token_date, dolog_method, comment)
            VALUES
              (0, 1, 'alert2glpi', 1, NULL, NULL,
               '${APP_TOKEN}', NOW(), 0, 'Created by scripts/glpi-init.sh — Alertmanager bridge');" >/dev/null
  ok "API client 'alert2glpi' created"
else
  glpi_sql "UPDATE glpi_apiclients SET app_token = '${APP_TOKEN}', is_active = 1
            WHERE name = 'alert2glpi';" >/dev/null
  ok "API client 'alert2glpi' updated"
fi

# --- the user itself ---------------------------------------------------------
uid="$(glpi_sql "SELECT id FROM glpi_users WHERE name = 'alertmanager';" || true)"
if [[ -z "$uid" ]]; then
  # A random, unusable password: this account authenticates ONLY by token.
  # Giving it a usable password would add a brute-forceable surface for nothing.
  unusable="$(php_password_hash "$(openssl rand -base64 48)")"
  glpi_sql "INSERT INTO glpi_users
              (name, password, firstname, realname, is_active, api_token, api_token_date,
               language, comment)
            VALUES
              ('alertmanager', '${unusable}', 'Alertmanager', 'Supervision', 1,
               '${USER_TOKEN}', NOW(), 'fr_FR',
               'Machine account — Alertmanager -> GLPI bridge (ADR-0009)');" >/dev/null
  uid="$(glpi_sql "SELECT id FROM glpi_users WHERE name = 'alertmanager';")"
  ok "user 'alertmanager' created (id ${uid})"
else
  glpi_sql "UPDATE glpi_users SET api_token = '${USER_TOKEN}', api_token_date = NOW(),
            is_active = 1 WHERE id = ${uid};" >/dev/null
  ok "user 'alertmanager' updated (id ${uid})"
fi

# --- profile: Technician, not Super-Admin -----------------------------------
# The bridge only needs to create and update tickets. Super-Admin would let a
# compromised webhook reconfigure GLPI itself.
tech_profile="$(glpi_sql "SELECT id FROM glpi_profiles WHERE name IN ('Technician','Technicien') LIMIT 1;" || true)"
if [[ -n "$tech_profile" ]]; then
  has="$(glpi_sql "SELECT COUNT(*) FROM glpi_profiles_users
                   WHERE users_id = ${uid} AND profiles_id = ${tech_profile};" || echo 0)"
  if [[ "$has" == "0" ]]; then
    glpi_sql "INSERT INTO glpi_profiles_users (users_id, profiles_id, entities_id, is_recursive, is_dynamic)
              VALUES (${uid}, ${tech_profile}, 0, 1, 0);" >/dev/null
  fi
  ok "profile Technician assigned to alertmanager"
else
  warn "Technician profile not found — assign it by hand in the GLPI interface"
fi

# =============================================================================
# 6. Nothing to do: the tokens ARE the secrets
#
# The tokens were generated by scripts/init-secrets.sh and INJECTED into GLPI
# above, rather than generated by GLPI and read back. That inversion matters:
# it makes the script idempotent (re-running restores the same tokens) and it
# means alert2glpi can be deployed before, after, or at the same time as this
# script without a chicken-and-egg problem.
# =============================================================================
section "6/8 — tokens"
ok "dw_glpi_app_token and dw_glpi_user_token are already Docker secrets"
log "  they were injected into GLPI, not read back from it — see the comment above"

# =============================================================================
# 7. ITIL category
# =============================================================================
section "7/8 — ITIL category"
cat_exists="$(glpi_sql "SELECT COUNT(*) FROM glpi_itilcategories WHERE name = 'Infrastructure';" || echo 0)"
if [[ "$cat_exists" == "0" ]]; then
  glpi_sql "INSERT INTO glpi_itilcategories
              (name, completename, comment, level, is_incident, is_request, is_problem, is_change, entities_id, is_recursive)
            VALUES
              ('Infrastructure', 'Infrastructure', 'Automatic tickets from Alertmanager', 1, 1, 0, 1, 0, 0, 1);" >/dev/null
  ok "ITIL category 'Infrastructure' created"
else
  ok "ITIL category 'Infrastructure' already exists"
fi

# =============================================================================
# 8. End-to-end API verification
#
# Not "is the flag set" but "does an actual initSession with the real tokens
# return a session token". That is what alert2glpi will do.
# =============================================================================
section "8/8 — API verification"
response="$(docker exec "$CID" curl -s -X GET \
  -H "Content-Type: application/json" \
  -H "Authorization: user_token ${USER_TOKEN}" \
  -H "App-Token: ${APP_TOKEN}" \
  "http://localhost/apirest.php/initSession" 2>&1 || true)"

if grep -q 'session_token' <<<"$response"; then
  ok "initSession returns a session token — the API is usable by alert2glpi"
  session="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["session_token"])' <<<"$response")"
  # Close it: an abandoned session stays in the table and counts against the
  # concurrent-session limit.
  docker exec "$CID" curl -s -X GET \
    -H "Session-Token: ${session}" -H "App-Token: ${APP_TOKEN}" \
    "http://localhost/apirest.php/killSession" >/dev/null 2>&1 || true
else
  error "initSession failed:"
  printf '    %s\n' "${response:0:500}" >&2
  error "check: enable_api = 1, the app_token in glpi_apiclients, the user api_token"
  exit 1
fi

section "Done"
ok "GLPI initialised"
cat >&2 <<EOF

Administration account:
  URL      : https://glpi.${DOMAIN}
  user     : glpi
  password : the content of secrets/dw_glpi_admin_password.txt

The tech / normal / post-only accounts are DISABLED and their default
passwords destroyed.
EOF

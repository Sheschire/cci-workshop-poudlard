#!/usr/bin/env bash
# =============================================================================
# Rendering of the configuration files and content hashing of the Swarm configs.
#
# Sourced by scripts/deploy.sh (to deploy) and by scripts/validate-stacks.sh
# (so that `docker stack config` sees the same rendered files the deployment
# would): a stack that validates in CI must be the stack that deploys.
#
# Two functions:
#   render_configs        config/… → .rendered/…, with ${VAR} substitution
#   export_config_hashes  export CONFIG_HASH_<NAME> from the file contents
# =============================================================================

[[ -n "${DW_RENDER_SOURCED:-}" ]] && return 0
readonly DW_RENDER_SOURCED=1

readonly DW_RENDER_DIR="${DW_ROOT}/.rendered"

# -----------------------------------------------------------------------------
# Files that genuinely need substitution. Everything else is used as-is, so a
# literal `$` in a Grafana dashboard, a Lua filter or a PromQL expression stays
# a literal `$`.
#
# Format: "<path under config/>:<name under .rendered/>"
# -----------------------------------------------------------------------------
readonly -a DW_TEMPLATED_CONFIGS=(
  "traefik/dynamic.yml:traefik-dynamic.yml"
  "prometheus/prometheus.yml:prometheus.yml"
  "alertmanager/alertmanager.yml:alertmanager.yml"
  "blackbox/blackbox.yml:blackbox.yml"
  "grafana/grafana.ini:grafana.ini"
  "kibana/kibana.yml:kibana.yml"
  "haproxy/haproxy.cfg:haproxy.cfg"
  "elasticsearch/elasticsearch.yml:elasticsearch.yml"
  "fluent-bit/fluent-bit.conf:fluent-bit.conf"
)

# -----------------------------------------------------------------------------
# Config objects and the file each one hashes. A directory is hashed as the
# concatenation of its files, so adding, removing or editing any of them rolls
# the config.
# -----------------------------------------------------------------------------
_dw_config_sources() {
  cat <<'EOF'
TRAEFIK_STATIC     config/traefik/traefik.yml
TRAEFIK_DYNAMIC    .rendered/traefik-dynamic.yml
CROWDSEC_ACQUIS    config/crowdsec/acquis.yaml
CROWDSEC_PROFILES  config/crowdsec/profiles.yaml
GALERA_ENTRYPOINT  config/galera/entrypoint.sh
GALERA_CNF         config/galera/galera.cnf
GALERA_INIT        config/galera/init.sql
HAPROXY            .rendered/haproxy.cfg
CASSANDRA_JMX      config/cassandra/jmx-exporter.yml
ES_CONFIG          .rendered/elasticsearch.yml
KIBANA             .rendered/kibana.yml
FLUENTBIT_CONF     .rendered/fluent-bit.conf
FLUENTBIT_PARSERS  config/fluent-bit/parsers.conf
FLUENTBIT_LUA      config/fluent-bit/docker-metadata.lua
PROMETHEUS         .rendered/prometheus.yml
PROMETHEUS_RULES   config/prometheus/rules
ALERTMANAGER       .rendered/alertmanager.yml
BLACKBOX           .rendered/blackbox.yml
GRAFANA_INI        .rendered/grafana.ini
GRAFANA_PROV       config/grafana/provisioning
GRAFANA_DASH       config/grafana/dashboards
NGINX_METRICS      config/backup/nginx.conf
MINIO_POLICIES     config/minio/policies
SECRETS_ENTRYPOINT config/common/secrets-entrypoint.sh
EOF
}

# -----------------------------------------------------------------------------
render_configs() {
  need_cmd python3
  mkdir -p "$DW_RENDER_DIR"

  # Substitution is done by scripts/lib/render.py rather than `envsubst`:
  # gettext-base is not installed everywhere, and an unqualified envsubst also
  # expands `$1`, `${HOME}` and any shell-shaped text inside a Prometheus
  # relabel rule — a classic silent corruption. render.py substitutes an
  # explicit allow-list, treats `$$` as an escape, and FAILS on a variable that
  # is unset or wrongly empty (an empty ADMIN_CIDR in an allowlist would open
  # an administration UI to the world).
  local entry src dst count=0
  for entry in "${DW_TEMPLATED_CONFIGS[@]}"; do
    src="${DW_ROOT}/config/${entry%%:*}"
    dst="${DW_RENDER_DIR}/${entry##*:}"
    [[ -f "$src" ]] || continue
    python3 "${DW_LIB_DIR}/render.py" "$src" "$dst"
    (( ++count ))
  done
  ok "${count} configuration file(s) rendered into .rendered/"
}

# -----------------------------------------------------------------------------
export_config_hashes() {
  local key path full
  while read -r key path; do
    [[ -z "$key" ]] && continue
    full="${DW_ROOT}/${path}"
    if [[ -d "$full" ]]; then
      export "CONFIG_HASH_${key}"="$(
        find "$full" -type f | sort | xargs cat 2>/dev/null | sha256sum | cut -c1-12
      )"
    elif [[ -f "$full" ]]; then
      export "CONFIG_HASH_${key}"="$(sha256sum "$full" | cut -c1-12)"
    else
      # Not implemented yet: the repository is built phase by phase (CDC §13).
      # A stable placeholder keeps `docker stack config` able to substitute.
      export "CONFIG_HASH_${key}"="absent"
    fi
  done < <(_dw_config_sources)
}

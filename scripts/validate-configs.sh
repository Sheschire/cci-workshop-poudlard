#!/usr/bin/env bash
# =============================================================================
# Static validation of everything under config/ that has a checker (CDC §11.3).
#
#   promtool check config / check rules / test rules   Prometheus
#   amtool check-config                                Alertmanager
#   YAML / JSON well-formedness                        blackbox, Grafana, …
#   Grafana provisioning coherence                     datasources ↔ dashboards
#
# Each block is *skipped with an explicit message* when its input does not exist
# yet: the repository is built phase by phase (CDC §13) and the CI must stay
# green at every step while still becoming a real gate as soon as the files
# land. A skipped block is reported, never silently ignored.
# =============================================================================
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

cd "$DW_ROOT"
rc=0
skipped=()

# The Prometheus rules and the Alertmanager configuration carry ${DOMAIN} in
# their annotations and URLs, so they must be RENDERED before promtool and
# amtool see them — exactly as a deployment would.
if [[ -f "${DW_ENV_FILE}" ]]; then
  source "$(dirname -- "${BASH_SOURCE[0]}")/lib/render.sh"
  load_env
  render_configs >/dev/null
fi

have() { [[ -e "$1" ]]; }
glob_has() { compgen -G "$1" >/dev/null 2>&1; }

run() {
  local label=$1; shift
  if "$@"; then
    ok "$label"
  else
    error "$label"
    rc=1
  fi
}

# --- Prometheus --------------------------------------------------------------
section "Prometheus"
if have .rendered/prometheus.yml; then
  need_cmd promtool
  run "promtool check config" promtool check config .rendered/prometheus.yml
else
  skipped+=("config/prometheus/prometheus.yml (phase 4)")
fi

if glob_has '.rendered/rules-*.yml'; then
  need_cmd promtool
  run "promtool check rules" promtool check rules .rendered/rules-*.yml
else
  skipped+=("config/prometheus/rules/*.yml (phase 4)")
fi

# Unit tests of the alerting rules: the only way to prove that a PromQL
# expression fires when it should, without a running cluster.
if glob_has 'config/prometheus/tests/*.yml'; then
  need_cmd promtool
  run "promtool test rules" promtool test rules config/prometheus/tests/*.yml
else
  skipped+=("config/prometheus/tests/*.yml (phase 4)")
fi

# --- Alertmanager ------------------------------------------------------------
section "Alertmanager"
if have .rendered/alertmanager.yml; then
  need_cmd amtool
  run "amtool check-config" amtool check-config .rendered/alertmanager.yml
else
  skipped+=("config/alertmanager/alertmanager.yml (phase 4)")
fi

# --- Traefik: cross-check the config against the stack labels ---------------
# Traefik drops a router with a dangling middleware reference *silently*: the
# URL 404s, or an administration UI quietly loses its allowlist. Neither
# yamllint nor `docker stack config` can see that.
section "Traefik"
if have config/traefik/dynamic.yml; then
  run "references resolve, administration routes carry admin-allowlist" \
    python3 "${DW_ROOT}/scripts/lib/check-traefik.py"
else
  skipped+=("config/traefik/ (phase 1)")
fi

# --- Generic YAML / JSON well-formedness ------------------------------------
# yamllint already covers style; this catches files it excludes (the Grafana
# dashboards) and proves that every JSON payload parses.
section "JSON files under config/"
if glob_has 'config/**'; then
  while IFS= read -r file; do
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$file" 2>/dev/null; then
      ok "$(basename "$file")"
    else
      error "invalid JSON: ${file}"
      rc=1
    fi
  done < <(find config -name '*.json' | sort)
else
  skipped+=("config/ (phase 1+)")
fi

# --- Grafana provisioning coherence -----------------------------------------
# A dashboard that references a datasource UID nobody provisions renders as an
# empty panel — exactly the failure mode acceptance criterion 4.2 forbids.
section "Grafana provisioning"
if have config/grafana/provisioning/datasources && glob_has 'config/grafana/dashboards/*.json'; then
  if python3 "${DW_ROOT}/scripts/lib/check-grafana.py"; then
    ok "datasource UIDs, panels and generator output are consistent"
  else
    error "Grafana provisioning is inconsistent"
    rc=1
  fi
else
  skipped+=("config/grafana/ (phase 4)")
fi

# --- Traefik middleware references in the monitoring stack ------------------
# Already covered by the Traefik block above, which walks every stack.

# --- Blackbox ----------------------------------------------------------------
section "Blackbox exporter"
if have config/blackbox/blackbox.yml; then
  run "blackbox.yml parses and declares the expected modules" \
    python3 - <<'PY'
import sys, yaml
cfg = yaml.safe_load(open("config/blackbox/blackbox.yml")) or {}
mods = cfg.get("modules") or {}
required = {"http_2xx", "http_2xx_glpi", "tcp_connect", "icmp"}
missing = required - set(mods)
if missing:
    print(f"missing blackbox modules: {sorted(missing)}", file=sys.stderr)
    sys.exit(1)
PY
else
  skipped+=("config/blackbox/blackbox.yml (phase 4)")
fi

# --- Summary -----------------------------------------------------------------
section "Summary"
if (( ${#skipped[@]} > 0 )); then
  warn "skipped (not implemented yet):"
  printf '    - %s\n' "${skipped[@]}" >&2
fi
if (( rc == 0 )); then
  ok "every present configuration file is valid"
else
  error "configuration validation failed"
fi
exit "$rc"

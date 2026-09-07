#!/usr/bin/env bash
# =============================================================================
# Print the /etc/hosts line that a client workstation must add to reach the
# platform through the VIP (CDC §3.1). `dockerwarts.lan` is deliberately not a
# real domain: there is no DNS server in the lab.
#
#   make hosts | sudo tee -a /etc/hosts
# =============================================================================
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

# Every host name published by Traefik (CDC §5.5).
HOSTNAMES=(traefik glpi grafana kibana prometheus alertmanager minio whoami vip)

printf '# Dockerwarts N°1 — add to /etc/hosts on the client workstation\n'
printf '%s' "$VIP"
for h in "${HOSTNAMES[@]}"; do printf ' %s.%s' "$h" "$DOMAIN"; done
printf '\n'

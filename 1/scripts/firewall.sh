#!/usr/bin/env bash
# =============================================================================
# Pare-feu de l'hôte — deuxième couche, sous Traefik.
#
#   ./scripts/firewall.sh              affiche les règles, ne modifie rien
#   sudo ./scripts/firewall.sh --appliquer
#
# Pourquoi un pare-feu hôte alors que Traefik filtre déjà : Docker écrit ses
# propres règles DNAT dans nftables, EN AMONT des chaînes d'ufw. Un port publié
# par un conteneur est donc joignable depuis l'extérieur même si `ufw status`
# affiche « deny ». C'est un piège classique, et la raison d'être de la chaîne
# DOCKER-USER, seule chaîne que Docker consulte et ne réécrit jamais.
#
# Ce script est facultatif : la plateforme fonctionne sans lui. Il durcit une
# installation réelle, sur une machine exposée.
#
# Documentation : docs/03-securite.md
# =============================================================================
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

APPLIQUER="${1:-}"

ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
info() { printf '\033[34m  ·\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗\033[0m %s\n' "$*" >&2; exit 1; }

# shellcheck disable=SC1091
source .env 2>/dev/null || true
ADMIN_CIDR="${ADMIN_CIDR:-10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}"

# Les règles, dans l'ordre où elles seront évaluées.
regles=(
  "# Connexions déjà établies : elles ne repassent pas par la politique."
  "iptables -I DOCKER-USER 1 -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN"
  ""
  "# Trafic entre conteneurs sur les réseaux internes de la plateforme."
  "iptables -I DOCKER-USER 2 -i br+ -o br+ -j RETURN"
  ""
  "# Les deux seuls ports que le monde extérieur a le droit d'atteindre."
  "iptables -I DOCKER-USER 3 -p tcp --dport 80  -j RETURN"
  "iptables -I DOCKER-USER 4 -p tcp --dport 443 -j RETURN"
  ""
  "# Tout le reste vers un conteneur est rejeté, y compris les ports qu'un"
  "# service publierait par erreur. C'est la règle qui compte."
  "iptables -A DOCKER-USER -j DROP"
)

echo
info "Plages autorisées pour l'administration (via Traefik) : ${ADMIN_CIDR}"
info "Ports ouverts sur l'hôte : 80 (redirigé), 443."
echo

if [[ "$APPLIQUER" != "--appliquer" ]]; then
  echo "  Règles qui seraient appliquées :"
  echo
  printf '    %s\n' "${regles[@]}"
  echo
  info "Rien n'a été modifié. Pour appliquer : sudo $0 --appliquer"
  exit 0
fi

[[ "$(id -u)" -eq 0 ]] || die "L'application des règles demande les droits root."
command -v iptables >/dev/null || die "iptables est introuvable."

# Purge d'abord : relancer le script ne doit pas empiler dix fois les mêmes
# règles, ce qui rendrait la chaîne illisible et le comportement imprévisible.
iptables -F DOCKER-USER 2>/dev/null || iptables -N DOCKER-USER

for regle in "${regles[@]}"; do
  [[ -z "$regle" || "$regle" == \#* ]] && continue
  info "$regle"
  eval "$regle"
done

echo
ok "Règles appliquées à la chaîne DOCKER-USER."
info "Elles ne survivent PAS au redémarrage : utilisez iptables-persistent"
info "ou netfilter-persistent pour les rendre permanentes."

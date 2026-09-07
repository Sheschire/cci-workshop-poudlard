#!/usr/bin/env bash
# =============================================================================
# Préparation de la plateforme — à lancer UNE FOIS avant `docker compose up`.
#
# Produit les trois choses qui ne peuvent pas être versionnées :
#   .env                      les mots de passe réels
#   certs/dockerwarts.{crt,key}  le certificat TLS auto-signé
#   secrets/users.htpasswd    l'empreinte du compte d'administration
#
# Le script est idempotent : il ne réécrit jamais un fichier existant, on peut
# donc le relancer sans crainte de perdre des identifiants.
# =============================================================================
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
info() { printf '\033[34m  ·\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗\033[0m %s\n' "$*" >&2; exit 1; }

command -v openssl >/dev/null || die "openssl est requis (certificat et empreinte du mot de passe)."

# -----------------------------------------------------------------------------
# 1. Le fichier .env
# -----------------------------------------------------------------------------
if [[ -f .env ]]; then
  info ".env existe déjà, conservé tel quel."
else
  cp .env.example .env
  # Des mots de passe tirés au sort valent mieux que des `change-me` qu'on
  # oublie de changer. 24 caractères base64 sans caractère spécial : assez
  # solide, et sans risque d'échappement dans les URL de connexion.
  for var in DB_PASSWORD DB_ROOT_PASSWORD GRAFANA_PASSWORD ADMIN_PASSWORD; do
    secret="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
    # Le délimiteur | évite tout conflit avec le contenu du mot de passe.
    sed -i.bak "s|^${var}=.*|${var}=${secret}|" .env
  done
  rm -f .env.bak
  ok ".env créé, avec quatre mots de passe tirés au hasard."
  warn "Notez le mot de passe Grafana : grep GRAFANA_PASSWORD .env"
fi

# Charge .env pour connaître DOMAIN, ADMIN_USER et ADMIN_PASSWORD.
# shellcheck disable=SC1091
set -a; source .env; set +a

: "${DOMAIN:?DOMAIN doit être défini dans .env}"
: "${ADMIN_USER:?ADMIN_USER doit être défini dans .env}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD doit être défini dans .env}"

# -----------------------------------------------------------------------------
# 2. Le certificat TLS
# -----------------------------------------------------------------------------
mkdir -p certs
if [[ -f certs/dockerwarts.crt && -f certs/dockerwarts.key ]]; then
  info "Certificat existant, conservé."
else
  # subjectAltName est obligatoire : les navigateurs actuels ne regardent plus
  # le CN du tout, et refusent le certificat sans cette extension.
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout certs/dockerwarts.key \
    -out    certs/dockerwarts.crt \
    -days 825 \
    -subj "/C=FR/O=Dockerwarts/CN=*.${DOMAIN}" \
    -addext "subjectAltName=DNS:${DOMAIN},DNS:*.${DOMAIN}" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" \
    2>/dev/null
  chmod 600 certs/dockerwarts.key
  ok "Certificat auto-signé créé pour *.${DOMAIN} (valable 825 jours)."
  warn "Auto-signé : le navigateur affichera un avertissement. C'est attendu."
fi

# -----------------------------------------------------------------------------
# 3. Le compte d'administration lu par Traefik
# -----------------------------------------------------------------------------
mkdir -p secrets
if [[ -f secrets/users.htpasswd ]]; then
  info "secrets/users.htpasswd existe déjà, conservé."
else
  # `openssl passwd -apr1` produit le format attendu par Traefik sans exiger
  # apache2-utils, qui n'est pas installé partout. L'empreinte, et non le mot
  # de passe, est ce qui atterrit sur le disque.
  hash="$(openssl passwd -apr1 "${ADMIN_PASSWORD}")"
  printf '%s:%s\n' "${ADMIN_USER}" "${hash}" > secrets/users.htpasswd
  chmod 600 secrets/users.htpasswd
  ok "secrets/users.htpasswd créé pour l'utilisateur « ${ADMIN_USER} »."
fi

# -----------------------------------------------------------------------------
# 4. Le répertoire des sauvegardes
# -----------------------------------------------------------------------------
mkdir -p backups
ok "Répertoire backups/ prêt."

# -----------------------------------------------------------------------------
# 5. Rappel sur la résolution de noms
# -----------------------------------------------------------------------------
if grep -q "glpi.${DOMAIN}" /etc/hosts 2>/dev/null; then
  ok "/etc/hosts contient déjà les noms de la plateforme."
else
  echo
  warn "Ajoutez ces noms à /etc/hosts (une seule fois, demande sudo) :"
  echo
  echo "  sudo tee -a /etc/hosts <<'EOF'"
  echo "  127.0.0.1 glpi.${DOMAIN} grafana.${DOMAIN} kibana.${DOMAIN} prometheus.${DOMAIN} traefik.${DOMAIN}"
  echo "  EOF"
fi

echo
ok "Préparation terminée. Lancez maintenant : docker compose up -d"

#!/usr/bin/env bash
# =============================================================================
# Vérification de l'état réel de la plateforme.
#
#   ./scripts/verify.sh
#
# Ne se contente pas de « le conteneur tourne » : interroge chaque service dans
# sa propre langue (SQL, API REST, CQL, HTTP) et sort en erreur si l'un d'eux
# ne répond pas. Utilisable après une installation, après une restauration, ou
# dans une tâche planifiée.
# =============================================================================
set -uo pipefail   # pas de -e : on veut TOUS les résultats, pas le premier échec

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

ECHECS=0

ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
ko()   { printf '\033[31m  ✗\033[0m %s\n' "$*"; ECHECS=$((ECHECS + 1)); }
titre(){ printf '\n\033[1m%s\033[0m\n' "$*"; }

# Exécute une commande et rapporte. Renvoie toujours 0 : c'est le compteur
# ECHECS qui décide du code de sortie final, pas la première commande ratée.
verifier() {
  local libelle="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$libelle"; else ko "$libelle"; fi
  return 0
}

# -----------------------------------------------------------------------------
titre "État des conteneurs"
# -----------------------------------------------------------------------------
# `cassandra-init` est un travail ponctuel : il DOIT être sorti, on l'exclut.
for service in traefik db glpi elasticsearch kibana cassandra prometheus grafana node-exporter cadvisor; do
  etat="$(docker compose ps --format '{{.State}}' "$service" 2>/dev/null | head -n1)"
  case "$etat" in
    running) ok "$service : running" ;;
    "")      ko "$service : absent" ;;
    *)       ko "$service : $etat" ;;
  esac
done

# -----------------------------------------------------------------------------
titre "Sondes de santé"
# -----------------------------------------------------------------------------
for service in traefik db glpi elasticsearch kibana cassandra prometheus grafana; do
  sante="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}aucune{{end}}' \
           "$(docker compose ps -q "$service" 2>/dev/null)" 2>/dev/null)"
  case "$sante" in
    healthy)  ok "$service : healthy" ;;
    aucune)   ok "$service : pas de sonde définie" ;;
    *)        ko "$service : ${sante:-inconnu}" ;;
  esac
done

# -----------------------------------------------------------------------------
titre "Réponses applicatives"
# -----------------------------------------------------------------------------
# Chaque service est interrogé dans son propre protocole : un port ouvert ne
# prouve rien, une réponse applicative correcte si.

# Guillemets simples voulus : $MARIADB_ROOT_PASSWORD doit être développé DANS
# le conteneur, pas ici — le mot de passe ne transite jamais par la ligne de
# commande de l'hôte, où il apparaîtrait dans `ps`.
# shellcheck disable=SC2016
verifier "MariaDB accepte une requête SQL" \
  docker compose exec -T db sh -c \
    'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "SELECT 1"'

verifier "GLPI répond GLPI_OK sur status.php" \
  docker compose exec -T glpi sh -c \
    'curl -sf http://localhost/status.php | grep -q GLPI_OK'

verifier "Elasticsearch au moins en état yellow" \
  docker compose exec -T elasticsearch sh -c \
    "curl -sf 'http://localhost:9200/_cluster/health?wait_for_status=yellow&timeout=5s'"

verifier "Kibana disponible" \
  docker compose exec -T kibana sh -c \
    "curl -sf http://localhost:5601/api/status | grep -q '\"level\":\"available\"'"

verifier "Cassandra : nœud Up/Normal" \
  docker compose exec -T cassandra sh -c "nodetool status | grep -q '^UN'"

# Interrogation d'une clé PRÉCISE, et non `LIMIT 1` : avec LIMIT, le contrôle
# dépend de la ligne que Cassandra renvoie en premier, qui change dès qu'une
# autre ligne est écrite. Il échouait après une restauration alors que tout
# allait bien.
verifier "Cassandra : le keyspace dockerwarts existe" \
  docker compose exec -T cassandra sh -c \
    "cqlsh -e \"SELECT valeur FROM dockerwarts.sante WHERE cle='initialisation'\" | grep -q ok"

verifier "Prometheus en bonne santé" \
  docker compose exec -T prometheus wget --spider -q http://localhost:9090/-/healthy

verifier "Grafana en bonne santé" \
  docker compose exec -T grafana wget --spider -q http://localhost:3000/api/health

# -----------------------------------------------------------------------------
titre "Collecte des métriques"
# -----------------------------------------------------------------------------
# La vraie question n'est pas « Prometheus tourne » mais « Prometheus voit-il
# encore ses quatre sources ». C'est ce que dit cette requête.
# La réponse a la forme {"value":[1788790660.548,"4"]} : la valeur utile est la
# SECONDE entrée du tableau, entre guillemets, la première étant l'horodatage.
cibles="$(docker compose exec -T prometheus \
  wget -qO- 'http://localhost:9090/api/v1/query?query=sum(up)' 2>/dev/null \
  | sed -n 's/.*"value":\[[0-9.]*,"\([0-9]*\)"\].*/\1/p')"

if [[ -n "$cibles" && "$cibles" -ge 4 ]]; then
  ok "Prometheus interroge $cibles cibles (4 attendues)"
else
  ko "Prometheus n'interroge que ${cibles:-0} cible(s) sur 4"
fi

# -----------------------------------------------------------------------------
titre "Pare-feu applicatif"
# -----------------------------------------------------------------------------
# Vérifie que Traefik protège bien les interfaces d'administration : une
# requête sans identifiants doit être refusée, pas servie.
source .env 2>/dev/null || true
DOMAIN="${DOMAIN:-dockerwarts.local}"

# --noproxy '*' : la requête vise 127.0.0.1, elle n'a rien à faire dans un
# proxy d'entreprise — qui la refuserait, et le refus ressemblerait à s'y
# méprendre à une panne de la plateforme.
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --noproxy '*' \
        --resolve "prometheus.${DOMAIN}:443:127.0.0.1" \
        "https://prometheus.${DOMAIN}/" 2>/dev/null)"
case "$code" in
  401|403) ok "Prometheus refuse l'accès anonyme (HTTP $code)" ;;
  000)     ko "Prometheus injoignable depuis l'extérieur (pas de réponse)" ;;
  *)       ko "Prometheus répond HTTP $code sans identifiants — la protection ne s'applique pas" ;;
esac

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --noproxy '*' \
        --resolve "glpi.${DOMAIN}:80:127.0.0.1" \
        "http://glpi.${DOMAIN}/" 2>/dev/null)"
case "$code" in
  301|302|307|308) ok "HTTP est redirigé vers HTTPS (HTTP $code)" ;;
  000)             ko "Le point d'entrée HTTP ne répond pas" ;;
  *)               ko "HTTP répond $code au lieu d'une redirection" ;;
esac

# -----------------------------------------------------------------------------
echo
if (( ECHECS == 0 )); then
  printf '\033[32m  Tout est opérationnel.\033[0m\n'
  exit 0
fi
printf '\033[31m  %d vérification(s) en échec.\033[0m\n' "$ECHECS"
exit 1

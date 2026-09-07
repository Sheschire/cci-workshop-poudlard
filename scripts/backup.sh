#!/usr/bin/env bash
# =============================================================================
# Sauvegarde complète de la plateforme.
#
#   ./scripts/backup.sh              sauvegarde dans backups/<horodatage>/
#   ./scripts/backup.sh /mnt/nas     sauvegarde ailleurs
#
# Principe : pour chaque donnée, on utilise l'outil de son moteur plutôt que de
# copier des fichiers sous les pieds d'un serveur qui écrit. Copier /var/lib/mysql
# à chaud produit une sauvegarde qui se restaure… parfois. C'est le pire des cas.
#
#   MariaDB        mariadb-dump --single-transaction  (cohérent, sans blocage)
#   Elasticsearch  API snapshot                        (incrémental, cohérent)
#   Cassandra      nodetool snapshot                   (liens durs, instantané)
#   Le reste       archive tar du volume               (données inertes)
#
# Documentation complète : docs/05-PRA.md
# =============================================================================
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

DEST_ROOT="${1:-$PWD/backups}"
STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
DEST="${DEST_ROOT}/${STAMP}"
# Nom de projet figé dans docker-compose.yml : les volumes en portent le préfixe.
PROJECT="dockerwarts"
# Nombre de sauvegardes conservées. Au-delà, les plus anciennes sont effacées.
RETENTION="${RETENTION:-7}"

ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
info() { printf '\033[34m  ·\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || die "docker est requis."
docker compose ps >/dev/null 2>&1 || die "La plateforme ne semble pas démarrée (docker compose up -d)."

mkdir -p "$DEST"
info "Destination : $DEST"

# -----------------------------------------------------------------------------
# Archive un volume Docker sans passer par l'hôte : un conteneur jetable monte
# le volume en lecture seule et écrit l'archive dans le répertoire cible.
# Fonctionne quel que soit l'emplacement réel des volumes sur la machine.
# -----------------------------------------------------------------------------
archive_volume() {
  local volume="$1" outfile="$2"
  docker run --rm \
    -v "${PROJECT}_${volume}:/source:ro" \
    -v "${DEST}:/backup" \
    alpine:3.22 \
    tar czf "/backup/${outfile}" -C /source .
}

# -----------------------------------------------------------------------------
# 1. MariaDB — le ticketing
# -----------------------------------------------------------------------------
info "MariaDB…"
# --single-transaction ouvre une transaction cohérente au lieu de verrouiller
# les tables : GLPI continue de fonctionner pendant la sauvegarde.
# --routines et --events : sans eux, les procédures et tâches planifiées sont
# silencieusement perdues, et on ne s'en aperçoit qu'à la restauration.
docker compose exec -T db sh -c \
  'exec mariadb-dump --single-transaction --routines --events --triggers \
     --all-databases -uroot -p"$MARIADB_ROOT_PASSWORD"' \
  | gzip -9 > "${DEST}/mariadb.sql.gz"
# Un dump vide fait 20 octets et ne lève aucune erreur : on vérifie la taille.
[[ -s "${DEST}/mariadb.sql.gz" ]] || die "Le dump MariaDB est vide."
ok "MariaDB : $(du -h "${DEST}/mariadb.sql.gz" | cut -f1)"

# -----------------------------------------------------------------------------
# 2. Elasticsearch — l'historisation
# -----------------------------------------------------------------------------
info "Elasticsearch…"
# Le dépôt pointe sur path.repo, déclaré dans docker-compose.yml. Le déclarer à
# chaque fois est sans effet s'il existe déjà, et indispensable après une
# reconstruction du volume.
docker compose exec -T elasticsearch curl -sf -XPUT \
  'http://localhost:9200/_snapshot/sauvegardes' \
  -H 'Content-Type: application/json' \
  -d '{"type":"fs","settings":{"location":"/usr/share/elasticsearch/data/snapshots","compress":true}}' \
  >/dev/null || die "Impossible de déclarer le dépôt de snapshots."

# wait_for_completion=true : le script attend la fin. Sans cela on archiverait
# un snapshot encore en cours d'écriture, donc inutilisable.
docker compose exec -T elasticsearch curl -sf -XPUT \
  "http://localhost:9200/_snapshot/sauvegardes/snap-${STAMP}?wait_for_completion=true" \
  -H 'Content-Type: application/json' \
  -d '{"indices":"*","include_global_state":true}' \
  > "${DEST}/elasticsearch-snapshot.json" || die "Le snapshot Elasticsearch a échoué."

grep -q '"state":"SUCCESS"' "${DEST}/elasticsearch-snapshot.json" \
  || die "Le snapshot Elasticsearch ne s'est pas terminé en SUCCESS."

# On n'archive QUE le sous-répertoire des snapshots, jamais les index vivants :
# copier `data/` à chaud produirait des index corrompus.
docker run --rm \
  -v "${PROJECT}_es_data:/source:ro" \
  -v "${DEST}:/backup" \
  alpine:3.22 \
  tar czf /backup/elasticsearch-snapshots.tar.gz -C /source snapshots
ok "Elasticsearch : $(du -h "${DEST}/elasticsearch-snapshots.tar.gz" | cut -f1)"

# -----------------------------------------------------------------------------
# 3. Cassandra — le datalake
# -----------------------------------------------------------------------------
info "Cassandra…"
# `nodetool snapshot` vide d'abord les mémoires tampons sur disque, puis crée
# des liens durs : instantané, cohérent, et sans copier un octet.
docker compose exec -T cassandra nodetool snapshot -t "snap-${STAMP}" dockerwarts \
  >/dev/null || die "Le snapshot Cassandra a échoué."

# On n'archive que les répertoires snapshots/, pas les données vivantes.
docker run --rm \
  -v "${PROJECT}_cassandra_data:/source:ro" \
  -v "${DEST}:/backup" \
  alpine:3.22 \
  sh -c "cd /source && tar czf /backup/cassandra-snapshot.tar.gz \
           \$(find . -type d -name 'snap-${STAMP}' -print)"

# Les liens durs restent sur le disque du nœud et retiennent l'espace des
# fichiers compactés : sans cette purge, le volume grossit à chaque sauvegarde.
docker compose exec -T cassandra nodetool clearsnapshot -t "snap-${STAMP}" dockerwarts \
  >/dev/null || warn "Purge du snapshot Cassandra impossible (à surveiller)."
ok "Cassandra : $(du -h "${DEST}/cassandra-snapshot.tar.gz" | cut -f1)"

# -----------------------------------------------------------------------------
# 4. Volumes de fichiers — données inertes, une archive suffit
# -----------------------------------------------------------------------------
info "Fichiers GLPI et Grafana…"
# glpi_config contient la clé de chiffrement de GLPI : sans elle, les mots de
# passe enregistrés (LDAP, SMTP, inventaire) sont irrécupérables après une
# restauration, même avec une base parfaitement saine.
for volume in glpi_files glpi_config glpi_plugins glpi_marketplace grafana_data; do
  archive_volume "$volume" "${volume}.tar.gz"
done
ok "Fichiers archivés."

# -----------------------------------------------------------------------------
# 5. Configuration — ce qui permet de reconstruire la plateforme
# -----------------------------------------------------------------------------
info "Configuration…"
# .env, certs/ et secrets/ ne sont PAS dans git : s'ils ne sont pas ici, ils
# n'existent nulle part ailleurs.
tar czf "${DEST}/configuration.tar.gz" \
  docker-compose.yml config/ scripts/ .env certs/ secrets/ 2>/dev/null \
  || warn "Certains fichiers de configuration sont absents."
chmod 600 "${DEST}/configuration.tar.gz"
ok "Configuration archivée (contient des secrets — droits 600)."

# -----------------------------------------------------------------------------
# 6. Manifeste et empreintes
# -----------------------------------------------------------------------------
(cd "$DEST" && sha256sum ./*.tar.gz ./*.gz > SHA256SUMS 2>/dev/null) || true

cat > "${DEST}/MANIFESTE.txt" <<EOF
Sauvegarde Dockerwarts
Date          : $(date -Is)
Hôte          : $(hostname)
Projet        : ${PROJECT}
Taille totale : $(du -sh "$DEST" | cut -f1)

Restauration  : ./scripts/restore.sh ${DEST}
Vérification  : cd ${DEST} && sha256sum -c SHA256SUMS
EOF

# -----------------------------------------------------------------------------
# 7. Rotation
# -----------------------------------------------------------------------------
count=$(find "$DEST_ROOT" -maxdepth 1 -mindepth 1 -type d | wc -l)
if (( count > RETENTION )); then
  # `sort` sur des noms au format ISO trie chronologiquement : les plus anciens
  # sont en tête, ce sont eux qu'on supprime.
  find "$DEST_ROOT" -maxdepth 1 -mindepth 1 -type d | sort | head -n "$(( count - RETENTION ))" \
    | while read -r vieux; do
        rm -rf "$vieux"
        info "Supprimée : $(basename "$vieux")"
      done
fi

echo
ok "Sauvegarde terminée — $(du -sh "$DEST" | cut -f1) dans $DEST"
cat "${DEST}/MANIFESTE.txt"

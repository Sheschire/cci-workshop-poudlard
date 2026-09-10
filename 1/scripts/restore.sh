#!/usr/bin/env bash
# =============================================================================
# Restauration de la plateforme à partir d'une sauvegarde.
#
#   ./scripts/restore.sh backups/2026-09-07_03-00-00
#   ./scripts/restore.sh backups/2026-09-07_03-00-00 --oui-je-suis-sur
#
# Opération DESTRUCTIVE : elle écrase les données actuelles. Le script demande
# confirmation, sauf si on lui passe --oui-je-suis-sur (pour les exercices de
# reprise automatisés).
#
# Procédure détaillée et objectifs de temps : docs/05-PRA.md
# =============================================================================
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SRC="${1:-}"
FORCE="${2:-}"
PROJECT="dockerwarts"

ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
info() { printf '\033[34m  ·\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗\033[0m %s\n' "$*" >&2; exit 1; }

[[ -n "$SRC" ]] || die "Usage : $0 <répertoire-de-sauvegarde> [--oui-je-suis-sur]"
[[ -d "$SRC" ]] || die "Répertoire introuvable : $SRC"
SRC="$(cd "$SRC" && pwd)"

# -----------------------------------------------------------------------------
# 0. Vérifier l'intégrité AVANT de détruire quoi que ce soit
# -----------------------------------------------------------------------------
if [[ -f "${SRC}/SHA256SUMS" ]]; then
  info "Vérification des empreintes…"
  (cd "$SRC" && sha256sum -c SHA256SUMS >/dev/null) \
    || die "Empreintes invalides : cette sauvegarde est corrompue, on n'y touche pas."
  ok "Empreintes conformes."
else
  warn "Pas de fichier SHA256SUMS : intégrité non vérifiable."
fi

if [[ "$FORCE" != "--oui-je-suis-sur" ]]; then
  echo
  warn "Cette opération ÉCRASE les données actuelles de la plateforme."
  echo "     Source : $SRC"
  read -r -p "  Taper « restaurer » pour continuer : " reponse
  [[ "$reponse" == "restaurer" ]] || die "Annulé."
fi

# -----------------------------------------------------------------------------
# Restaure un volume Docker depuis une archive.
# Le volume est vidé d'abord : sans cela, des fichiers de l'ancienne
# installation survivent dans la nouvelle et produisent des incohérences
# introuvables des semaines plus tard.
# -----------------------------------------------------------------------------
restore_volume() {
  local volume="$1" archive="$2"
  [[ -f "${SRC}/${archive}" ]] || { warn "Absent de la sauvegarde : ${archive}"; return 0; }
  docker volume create "${PROJECT}_${volume}" >/dev/null
  docker run --rm \
    -v "${PROJECT}_${volume}:/target" \
    -v "${SRC}:/backup:ro" \
    alpine:3.22 \
    sh -c 'rm -rf /target/..?* /target/.[!.]* /target/*  2>/dev/null; \
           tar xzf "/backup/'"${archive}"'" -C /target'
}

# -----------------------------------------------------------------------------
# 1. Tout arrêter
# -----------------------------------------------------------------------------
info "Arrêt de la plateforme…"
docker compose down
ok "Plateforme arrêtée."

# -----------------------------------------------------------------------------
# 2. Restaurer les volumes de fichiers pendant que rien ne tourne
# -----------------------------------------------------------------------------
info "Restauration des volumes de fichiers…"
for volume in glpi_files glpi_config glpi_plugins glpi_marketplace grafana_data; do
  restore_volume "$volume" "${volume}.tar.gz"
done
ok "Volumes de fichiers restaurés."

# -----------------------------------------------------------------------------
# 2 bis. Le dépôt de snapshots Elasticsearch
#
# Il vit DANS le volume de données (voir docker-compose.yml). On repart donc
# d'un volume vierge ne contenant que le dépôt : Elasticsearch réinitialise un
# nœud neuf autour, puis on lui demande de restaurer les index depuis ce dépôt.
# -----------------------------------------------------------------------------
if [[ -f "${SRC}/elasticsearch-snapshots.tar.gz" ]]; then
  info "Restauration du dépôt de snapshots Elasticsearch…"
  docker volume rm "${PROJECT}_es_data" >/dev/null 2>&1 || true
  docker volume create "${PROJECT}_es_data" >/dev/null
  docker run --rm \
    -v "${PROJECT}_es_data:/target" \
    -v "${SRC}:/backup:ro" \
    alpine:3.22 \
    sh -c 'tar xzf /backup/elasticsearch-snapshots.tar.gz -C /target && \
           chown -R 1000:0 /target && chmod 775 /target'
  # Le chown est indispensable : un volume neuf appartient à root, et
  # Elasticsearch tourne en uid 1000. Sans lui, le nœud refuse de démarrer.
  ok "Dépôt de snapshots en place."
else
  warn "Pas d'archive Elasticsearch dans cette sauvegarde."
fi

# -----------------------------------------------------------------------------
# 3. MariaDB
# -----------------------------------------------------------------------------
info "Redémarrage de MariaDB…"
# Le volume de données n'est pas restauré tel quel : on repart d'une base
# vierge et on rejoue le dump. C'est plus lent, mais c'est la seule méthode qui
# fonctionne quelle que soit la version de MariaDB qui a produit la sauvegarde.
docker volume rm "${PROJECT}_db_data" >/dev/null 2>&1 || true
docker compose up -d db

info "Attente que MariaDB accepte les connexions…"
for _ in $(seq 1 60); do
  if docker compose exec -T db healthcheck.sh --connect >/dev/null 2>&1; then break; fi
  sleep 5
done
docker compose exec -T db healthcheck.sh --connect >/dev/null 2>&1 \
  || die "MariaDB n'est pas prête après 5 minutes."

info "Rejeu du dump SQL…"
gunzip -c "${SRC}/mariadb.sql.gz" \
  | docker compose exec -T db sh -c 'exec mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"'
ok "MariaDB restaurée."

# -----------------------------------------------------------------------------
# 4. Elasticsearch
# -----------------------------------------------------------------------------
info "Redémarrage d'Elasticsearch…"
docker compose up -d elasticsearch
for _ in $(seq 1 60); do
  if docker compose exec -T elasticsearch \
       curl -sf 'http://localhost:9200/_cluster/health?wait_for_status=yellow&timeout=5s' >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

docker compose exec -T elasticsearch curl -sf -XPUT \
  'http://localhost:9200/_snapshot/sauvegardes' \
  -H 'Content-Type: application/json' \
  -d '{"type":"fs","settings":{"location":"/usr/share/elasticsearch/data/snapshots","compress":true}}' >/dev/null

# On restaure le snapshot le plus récent du dépôt.
snap="$(docker compose exec -T elasticsearch \
  curl -sf 'http://localhost:9200/_cat/snapshots/sauvegardes?h=id&s=id' \
  | tail -n1 | tr -d '[:space:]')"

if [[ -n "$snap" ]]; then
  # Un index ouvert refuse d'être restauré : il faut le fermer, ou le
  # supprimer. On ferme, c'est réversible.
  docker compose exec -T elasticsearch \
    curl -sf -XPOST 'http://localhost:9200/_all/_close' >/dev/null 2>&1 || true
  docker compose exec -T elasticsearch curl -sf -XPOST \
    "http://localhost:9200/_snapshot/sauvegardes/${snap}/_restore?wait_for_completion=true" \
    -H 'Content-Type: application/json' \
    -d '{"indices":"*","include_global_state":true}' >/dev/null \
    || warn "La restauration Elasticsearch a échoué — voir docker compose logs elasticsearch"
  ok "Elasticsearch restauré depuis ${snap}."
else
  warn "Aucun snapshot trouvé dans le dépôt : rien à restaurer côté Elasticsearch."
fi

# -----------------------------------------------------------------------------
# 5. Cassandra
# -----------------------------------------------------------------------------
info "Redémarrage de Cassandra…"
docker compose up -d cassandra
for _ in $(seq 1 60); do
  if docker compose exec -T cassandra cqlsh -e 'SELECT now() FROM system.local' >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

# L'ORDRE EST CRITIQUE, et il a coûté une restauration ratée avant d'être fixé.
#
# Cassandra range chaque table dans un répertoire suffixé d'un identifiant
# unique, tiré à la CRÉATION de la table : `sante-98e033c0aac6…`. Cet
# identifiant change à chaque recréation du schéma.
#
# Replacer les fichiers AVANT de recréer le schéma dépose donc les SSTables
# dans un répertoire portant l'ancien identifiant. Cassandra crée ensuite les
# siens, avec de nouveaux identifiants, ignore les fichiers restaurés — et
# tombe sur un `NoSuchFileException` au démarrage suivant.
#
# On recrée donc le schéma d'abord, puis on copie dans les répertoires
# RÉELLEMENT créés, retrouvés par le nom de la table et non par l'identifiant.
info "Recréation du schéma…"
docker compose up cassandra-init >/dev/null 2>&1 || true

if [[ -f "${SRC}/cassandra-snapshot.tar.gz" ]]; then
  info "Replacement des SSTables…"
  docker run --rm \
    -v "${PROJECT}_cassandra_data:/target" \
    -v "${SRC}:/backup:ro" \
    alpine:3.22 \
    sh -c '
      set -e
      mkdir -p /tmp/snap
      tar xzf /backup/cassandra-snapshot.tar.gz -C /tmp/snap
      find /tmp/snap -type d -name "snap-*" | while read -r d; do
        # .../<table>-<32 hexa>/snapshots/snap-xxx  →  <table>
        table=$(basename "$(dirname "$(dirname "$d")")" | sed "s/-[0-9a-f]\{32\}$//")
        dest=$(find /target/data/dockerwarts -maxdepth 1 -type d -name "${table}-*" | head -n1)
        if [ -z "$dest" ]; then
          echo "  table absente du schéma, ignorée : $table" >&2
          continue
        fi
        cp -f "$d"/*.db "$d"/*.txt "$d"/*.crc32 "$dest"/ 2>/dev/null || true
      done
      # Les fichiers arrivent en root alors que Cassandra tourne en uid 999 :
      # sans ce chown, le nœud refuse de démarrer au redémarrage suivant.
      chown -R 999:999 /target/data/dockerwarts
    '

  # `nodetool refresh` fait relire le répertoire à chaud, sans redémarrage.
  for table in evenements mesures sante; do
    docker compose exec -T cassandra nodetool refresh dockerwarts "$table" \
      >/dev/null 2>&1 || warn "refresh impossible sur ${table}"
  done
  ok "Cassandra restauré."
else
  warn "Pas d'archive Cassandra dans cette sauvegarde."
fi

# -----------------------------------------------------------------------------
# 6. Tout relancer
# -----------------------------------------------------------------------------
info "Redémarrage complet de la plateforme…"
docker compose up -d

echo
ok "Restauration terminée."
info "Vérifiez maintenant l'état réel des services : ./scripts/verify.sh"

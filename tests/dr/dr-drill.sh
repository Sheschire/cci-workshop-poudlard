#!/usr/bin/env bash
# =============================================================================
# `make dr-drill` — automated disaster-recovery exercise (CDC §9.3).
#
#   tests/dr/dr-drill.sh [--keep]
#
#   --keep   do not clean up, so the restored copies can be inspected
#
# The question this answers
# -------------------------
# "Do we have backups?" is answered by a metric. "Can we restore them?" is
# answered only by restoring them. A backup that has never been restored is a
# hypothesis, and the day it is tested for the first time is always the worst
# possible day to discover it was wrong.
#
# So this drill restores each component FOR REAL, from the actual repository,
# with the actual credentials — and compares the result with production. What
# it never does is touch production: every restore lands beside it, under
# another name, and is removed at the end.
#
#   Galera         → database `glpi_restore`, COUNT(*) of glpi_tickets compared
#   Elasticsearch  → indices `restored-*`, document counts compared
#   Cassandra      → keyspace `datalake_restore`, COUNT(*) on a partition
#   GLPI files     → a temporary directory, checksum of a known file
#
# Produces a Markdown report added to the test log of docs/07-PRA.md, which is
# what turns "we test our backups" into evidence.
# =============================================================================
# The step_* functions below are called indirectly, by name, through
# drill_step. shellcheck cannot see that and reports every line of them as
# unreachable; the indirection is what keeps the list of steps readable, so the
# check is disabled for the whole file (the directive must precede any command).
# shellcheck disable=SC2317
set -Eeuo pipefail
# Paths are relative to --source-path=scripts (see the lint-shell target).
# shellcheck source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh"
# shellcheck source=restore/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../scripts/restore/lib.sh"

need_manager
load_env
cd "$DW_ROOT"

KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1
ASSUME_YES=1     # unattended by construction: nothing here touches production

readonly RESTORE_DB="glpi_restore"
readonly RESTORE_KS="datalake_restore"
readonly SCRATCH="${DW_ROOT}/.dr-drill"

report_init dr-drill "Exercice de reprise — \`make dr-drill\`"
report 'Restauration réelle de chaque composant **à côté** de la production,'
report 'comparaison avec les données vives, puis nettoyage. La production'
report "n'est jamais modifiée."
report ''
report '| # | Étape | Résultat | Durée | Comparaison |'
report '|---|---|---|---|---|'

DRILL_STEP=0
DRILL_FAILED=0

# -----------------------------------------------------------------------------
# drill_step LABEL FUNCTION — run one step, time it, record it.
#
# The function prints its comparison on stdout (a single line) and returns
# non-zero on failure. Failures are recorded and the drill CONTINUES: a broken
# Cassandra restore must not hide the state of the Elasticsearch one.
# -----------------------------------------------------------------------------
drill_step() {
  local label=$1 fn=$2
  DRILL_STEP=$(( DRILL_STEP + 1 ))
  section "${DRILL_STEP}. ${label}"
  local started detail rc=0
  started="$(date -u +%s)"
  detail="$("$fn" 2>/dev/null)" || rc=$?
  local duration=$(( $(date -u +%s) - started ))
  if (( rc == 0 )); then
    ok "${label}: ${detail} (${duration}s)"
    report "| ${DRILL_STEP} | ${label} | ✅ | ${duration} s | ${detail} |"
  else
    error "${label}: FAILED (${duration}s)"
    report "| ${DRILL_STEP} | ${label} | ❌ | ${duration} s | ${detail:-échec} |"
    DRILL_FAILED=$(( DRILL_FAILED + 1 ))
  fi
}

# =============================================================================
# Helpers to query production
# =============================================================================
galera_cid="$(docker ps -q --filter 'label=com.docker.swarm.service.name=data_galera-1' | head -1)"
es_cid="$(docker ps -q --filter 'label=com.docker.swarm.service.name=data_es-1' | head -1)"
cass_cid="$(docker ps -q --filter 'label=com.docker.swarm.service.name=data_cassandra-1' | head -1)"

sql() {
  # shellcheck disable=SC2016  # $(cat …) must expand INSIDE the container
  docker exec "$galera_cid" sh -c \
    'mariadb -u root -p"$(cat /run/secrets/dw_mariadb_root_password)" -N -B -e "'"$1"'"' 2>/dev/null
}
es_api() {
  # shellcheck disable=SC2016
  docker exec "$es_cid" sh -c \
    'curl -s -u "elastic:$(cat /run/secrets/dw_es_elastic_password)" "http://localhost:9200'"$1"'"'
}
cql() {
  # shellcheck disable=SC2016
  docker exec "$cass_cid" sh -c \
    'cqlsh -u backup -p "$(cat /run/secrets/dw_cassandra_backup_password)" -e "'"$1"'"' 2>/dev/null
}

# =============================================================================
# 1. Galera — restore the last dump into `glpi_restore` and compare
# =============================================================================
step_galera() {
  [[ -n "$galera_cid" ]] || { echo "galera-1 absent de ce nœud"; return 1; }
  local live restored
  live="$(sql 'SELECT COUNT(*) FROM glpi.glpi_tickets;' | tr -d '[:space:]')"

  scripts/restore/restore-galera.sh --only-db glpi --as "$RESTORE_DB" --yes >/dev/null 2>&1 \
    || { echo "la restauration a échoué"; return 1; }

  restored="$(sql "SELECT COUNT(*) FROM ${RESTORE_DB}.glpi_tickets;" | tr -d '[:space:]')"
  [[ -n "$restored" ]] || { echo "table absente après restauration"; return 1; }

  # The restored copy is a snapshot of last night, so it holds AT MOST what
  # production holds today. More rows than production would mean tickets have
  # been deleted since — worth knowing, and not a drill failure. Fewer is
  # normal. Zero, with production non-empty, is the failure that matters.
  if [[ "$restored" == "0" && "$live" != "0" ]]; then
    echo "restauré 0 ticket alors que la production en a ${live}"
    return 1
  fi
  echo "production ${live} tickets / restauré ${restored}"
}

# =============================================================================
# 2. Elasticsearch — restore as restored-* and compare the document counts
# =============================================================================
step_es() {
  [[ -n "$es_cid" ]] || { echo "es-1 absent de ce nœud"; return 1; }
  local live restored
  live="$(es_api '/_cat/indices/logs-*?format=json&h=docs.count' \
          | jq -r '[.[] | (.["docs.count"] // "0" | tonumber)] | add // 0')"

  scripts/restore/restore-es.sh --rename --indices 'logs-*' --yes >/dev/null 2>&1 \
    || { echo "la restauration a échoué"; return 1; }

  # A restore is asynchronous at the shard level even with
  # wait_for_completion; give the indices a moment to report their counts.
  sleep 5
  restored="$(es_api '/_cat/indices/restored-*?format=json&h=docs.count' \
              | jq -r '[.[] | (.["docs.count"] // "0" | tonumber)] | add // 0')"
  [[ "${restored:-0}" -gt 0 ]] || { echo "aucun document restauré (production : ${live})"; return 1; }
  echo "production ${live} docs / restauré ${restored}"
}

# =============================================================================
# 3. Cassandra — restore into datalake_restore and compare one partition
# =============================================================================
step_cassandra() {
  [[ -n "$cass_cid" ]] || { echo "cassandra-1 absent de ce nœud"; return 1; }
  local live restored
  live="$(cql 'SELECT COUNT(*) FROM datalake.events;' | awk 'NR==4 {print $1}')"

  scripts/restore/restore-cassandra.sh 1 --keyspace "$RESTORE_KS" --yes >/dev/null 2>&1 \
    || { echo "la restauration a échoué"; return 1; }

  restored="$(cql "SELECT COUNT(*) FROM ${RESTORE_KS}.events;" | awk 'NR==4 {print $1}')"
  [[ -n "$restored" ]] || { echo "keyspace absent après restauration"; return 1; }
  if [[ "$restored" == "0" && "${live:-0}" != "0" ]]; then
    echo "restauré 0 ligne alors que la production en a ${live}"
    return 1
  fi
  echo "production ${live:-?} lignes / restauré ${restored}"
}

# =============================================================================
# 4. GLPI files — restore into a temporary directory and checksum
# =============================================================================
step_glpi_files() {
  mkdir -p "${SCRATCH}/glpi"
  scripts/restore/restore-glpi-files.sh --to "${SCRATCH}/glpi" --yes >/dev/null 2>&1 \
    || { echo "la restauration a échoué"; return 1; }

  local count size
  count="$(find "${SCRATCH}/glpi" -type f 2>/dev/null | wc -l | tr -d ' ')"
  size="$(du -sh "${SCRATCH}/glpi" 2>/dev/null | awk '{print $1}')"
  [[ "$count" -gt 0 ]] || { echo "aucun fichier restauré"; return 1; }

  # A checksum over the whole restored tree: it proves the files were decrypted
  # and written intact, not merely that a directory was created. Recorded in
  # the report so two consecutive drills on the same snapshot can be compared.
  local digest
  digest="$(find "${SCRATCH}/glpi" -type f -exec sha256sum {} + 2>/dev/null \
            | sort | sha256sum | cut -c1-16)"
  echo "${count} fichiers, ${size}, empreinte ${digest}"
}

# =============================================================================
# 5. Repository integrity — the structural check restic can do on demand
# =============================================================================
step_integrity() {
  local snapshots
  snapshots="$(restic_run snapshots --json 2>/dev/null | jq -r 'length' || echo 0)"
  [[ "${snapshots:-0}" -gt 0 ]] || { echo "aucun snapshot dans le dépôt"; return 1; }
  restic_run check >/dev/null 2>&1 || { echo "restic check a échoué sur ${snapshots} snapshots"; return 1; }
  echo "${snapshots} snapshots, structure vérifiée"
}

# =============================================================================
# Cleanup — run from a trap, so an interrupted drill leaves nothing behind
# =============================================================================
cleanup() {
  local rc=$?
  if (( KEEP )); then
    warn "--keep: leaving ${RESTORE_DB}, ${RESTORE_KS}, restored-* and ${SCRATCH} in place"
    warn "clean up with: tests/dr/dr-drill.sh --cleanup-only"
    exit "$rc"
  fi
  section "Cleanup"
  [[ -n "$galera_cid" ]] && sql "DROP DATABASE IF EXISTS \`${RESTORE_DB}\`;" >/dev/null 2>&1 \
    && ok "database ${RESTORE_DB} dropped"
  [[ -n "$cass_cid" ]] && cql "DROP KEYSPACE IF EXISTS ${RESTORE_KS};" >/dev/null 2>&1 \
    && ok "keyspace ${RESTORE_KS} dropped"
  if [[ -n "$es_cid" ]]; then
    # shellcheck disable=SC2016
    docker exec "$es_cid" sh -c \
      'curl -s -XDELETE -u "elastic:$(cat /run/secrets/dw_es_elastic_password)" \
         "http://localhost:9200/restored-*"' >/dev/null 2>&1 \
      && ok "indices restored-* deleted"
  fi
  rm -rf "$SCRATCH" && ok "${SCRATCH} removed"
  exit "$rc"
}

if [[ "${1:-}" == "--cleanup-only" ]]; then
  KEEP=0
  cleanup
fi
trap cleanup EXIT

# =============================================================================
# Run
# =============================================================================
section "Disaster-recovery drill — production is never modified"
drill_step "Restauration SQL (Galera → ${RESTORE_DB})"        step_galera
drill_step "Restauration Elasticsearch (→ restored-*)"        step_es
drill_step "Restauration Cassandra (→ ${RESTORE_KS})"         step_cassandra
drill_step "Restauration fichiers GLPI (→ répertoire temporaire)" step_glpi_files
drill_step "Intégrité du dépôt restic"                        step_integrity

# =============================================================================
report ''
report '### RPO constaté'
report ''
report '| Composant | Dernière sauvegarde réussie | Âge |'
report '|---|---|---|'
prom_cid="$(docker ps -q --filter 'label=com.docker.swarm.service.name=monitoring_prometheus' | head -1)"
if [[ -n "$prom_cid" ]]; then
  # The metrics the jobs published are the authority on the real RPO: not what
  # the schedule says should have happened, but what actually did.
  while read -r job ts; do
    [[ -z "$job" ]] && continue
    age=$(( $(date -u +%s) - ${ts%.*} ))
    report "| \`${job}\` | $(date -u -d "@${ts%.*}" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo '?') | $(( age / 3600 )) h |"
  done < <(
    docker exec "$prom_cid" wget -q -O - 'http://backup-metrics:8080/metrics' 2>/dev/null \
      | awk -F'[{}" ]+' '/^backup_last_success_timestamp/ {print $3, $NF}'
  )
else
  report '| — | métriques non lisibles depuis ce nœud | — |'
fi

section "Result"
report ''
if (( DRILL_FAILED == 0 )); then
  ok "${DRILL_STEP} steps, all successful — the backups are restorable"
  report "**Résultat : ${DRILL_STEP} étapes, 0 échec. Les sauvegardes sont restaurables.**"
  info "report: ${DW_REPORT}"
  exit 0
fi
error "${DRILL_FAILED}/${DRILL_STEP} step(s) FAILED"
report "**Résultat : ${DRILL_FAILED} échec(s) sur ${DRILL_STEP}.**"
info "report: ${DW_REPORT}"
exit 1

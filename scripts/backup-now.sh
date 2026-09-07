#!/usr/bin/env bash
# =============================================================================
# `make backup-now` — run every backup job now, and say whether it worked.
#
#   scripts/backup-now.sh                    every job, in dependency order
#   scripts/backup-now.sh backup-galera …    only the named jobs
#   scripts/backup-now.sh --list             what would run
#
# Why this script exists at all
# -----------------------------
# The jobs are `replicas: 0` services that swarm-cronjob scales to 1 at their
# scheduled minute. Waiting until 02:00 to find out whether a backup works is
# not a test strategy, and `docker service scale x=1` on its own tells you the
# service was scaled — not whether the job succeeded.
#
# So this drives the same mechanism swarm-cronjob does (scale to 1, let the
# task run to completion, scale back to 0) and then reads the TASK's exit
# status, which is the only place the truth is recorded once the container is
# gone. It produces the Markdown report quoted by docs/07-PRA.md.
# =============================================================================
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

need_manager
load_env
cd "$DW_ROOT"

readonly STACK=backup

# Order matters. The producers first, in the order of the nightly timetable;
# then restic-forget, which takes the repository lock and must not fight a
# backup for it; then the off-site mirror, so it copies what was just written
# rather than yesterday's repository.
readonly DEFAULT_JOBS=(
  backup-es
  backup-galera
  backup-glpi-files
  backup-cassandra-1
  backup-cassandra-2
  backup-cassandra-3
  backup-prometheus
  backup-crowdsec
  backup-configs
  restic-forget
  offsite-mirror
)

# Deliberately NOT in the default list: maint-cassandra-repair is not a backup
# and can run for hours on a loaded cluster. Run it explicitly when you mean
# to: scripts/backup-now.sh maint-cassandra-repair

readonly TIMEOUT="${JOB_TIMEOUT:-1800}"

JOBS=()
if [[ "${1:-}" == "--list" ]]; then
  printf '%s\n' "${DEFAULT_JOBS[@]}"
  exit 0
elif (( $# > 0 )); then
  JOBS=("$@")
else
  JOBS=("${DEFAULT_JOBS[@]}")
fi

docker service ls --format '{{.Name}}' | grep -q "^${STACK}_" \
  || die "the '${STACK}' stack is not deployed — run: make deploy-backup"

report_init backup-now "Exécution manuelle des sauvegardes — \`make backup-now\`"
report '| Job | Résultat | Durée | Détail |'
report '|---|---|---|---|'

# -----------------------------------------------------------------------------
# run_job NAME — scale to 1, wait for the task to finish, scale back to 0.
#
# Returns 0 only if the task reached state `complete`. A task that is still
# running when the timeout expires is a failure: an unbounded backup would
# block the whole sequence and, at 02:00, collide with the next job.
# -----------------------------------------------------------------------------
run_job() {
  local job=$1
  local svc="${STACK}_${job}"
  local started duration state err

  docker service inspect "$svc" >/dev/null 2>&1 || {
    warn "${job}: no such service — skipped"
    report "| \`${job}\` | ⚠️ absent | — | service inconnu dans la stack ${STACK} |"
    return 0
  }

  section "${job}"
  started="$(date -u +%s)"

  # Scale to 0 first: a service left at 1 by a previous run would keep its old,
  # completed task and `--replicas 1` would be a no-op. This is exactly what
  # swarm-cronjob does, and the reason a job can be re-run at all.
  docker service update --detach=true --replicas 0 "$svc" >/dev/null
  docker service update --detach=true --replicas 1 "$svc" >/dev/null

  # Poll the task rather than the service: `docker service ls` shows 0/1 both
  # while the task is starting and after it has finished, so it cannot tell
  # "not yet" from "done".
  local elapsed=0
  state=""
  while (( elapsed < TIMEOUT )); do
    state="$(docker service ps "$svc" --no-trunc \
               --format '{{.CurrentState}}' 2>/dev/null | head -1)"
    case "$state" in
      Complete*|Failed*|Rejected*|Orphaned*) break ;;
    esac
    sleep 5
    elapsed=$(( elapsed + 5 ))
  done

  duration=$(( $(date -u +%s) - started ))
  err="$(docker service ps "$svc" --no-trunc --format '{{.Error}}' 2>/dev/null | head -1)"

  # Back to 0 whatever happened: a job left at 1 would be restarted by the next
  # `docker stack deploy` and would run outside its window.
  docker service update --detach=true --replicas 0 "$svc" >/dev/null

  case "$state" in
    Complete*)
      ok "${job}: complete in ${duration}s"
      report "| \`${job}\` | ✅ succès | ${duration} s | — |"
      return 0
      ;;
    "")
      error "${job}: no task appeared within ${TIMEOUT}s"
      report "| \`${job}\` | ❌ échec | ${duration} s | aucune tâche planifiée (contrainte de placement ?) |"
      ;;
    *)
      error "${job}: ${state} ${err}"
      report "| \`${job}\` | ❌ échec | ${duration} s | ${state} ${err} |"
      # The container logs are the only place the job's own diagnosis lives.
      docker service logs --raw --tail 30 "$svc" 2>&1 | sed 's/^/    /' >&2 || true
      ;;
  esac
  return 1
}

failed=()
for job in "${JOBS[@]}"; do
  run_job "$job" || failed+=("$job")
done

# -----------------------------------------------------------------------------
# Cross-check against what the jobs themselves published.
#
# A job can exit 0 and still not have published a metric — if /metrics was not
# mounted, for instance. Prometheus would then see nothing and BackupTooOld
# would fire hours later. Reading the metrics file back closes that gap now.
# -----------------------------------------------------------------------------
section "Metrics published"
# backup-metrics only listens on the `monitoring` overlay, so it is read from
# inside a container attached to it. Prometheus is the natural choice: reading
# it from there checks the exact path the scrape takes, not an equivalent one.
metrics=""
prom_cid="$(docker ps -q --filter 'label=com.docker.swarm.service.name=monitoring_prometheus' | head -1)"
if [[ -n "$prom_cid" ]]; then
  metrics="$(docker exec "$prom_cid" wget -q -O - 'http://backup-metrics:8080/metrics' 2>/dev/null || true)"
fi

if [[ -n "$metrics" ]]; then
  report ''
  report '### Métriques publiées'
  report ''
  report '```'
  while IFS= read -r line; do
    [[ "$line" == \#* || -z "$line" ]] && continue
    report "$line"
  done <<<"$metrics"
  report '```'
  count="$(grep -c '^backup_last_status' <<<"$metrics" || true)"
  ok "${count} job(s) have published a metric"
else
  warn "could not read backup-metrics (run this from a node hosting Prometheus)"
  report ''
  report '> Métriques non relues depuis ce nœud.'
fi

section "Summary"
if (( ${#failed[@]} == 0 )); then
  ok "${#JOBS[@]} job(s), all successful"
  report ''
  report "**Résultat : ${#JOBS[@]} jobs, 0 échec.**"
  exit 0
fi
error "${#failed[@]}/${#JOBS[@]} job(s) FAILED: ${failed[*]}"
report ''
report "**Résultat : ${#failed[@]} échec(s) sur ${#JOBS[@]} — ${failed[*]}.**"
exit 1

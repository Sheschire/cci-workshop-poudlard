#!/usr/bin/env bash
# =============================================================================
# restore-es — restore Elasticsearch indices from a snapshot (CDC §9.2).
#
#   scripts/restore/restore-es.sh [options] [snapshot-name]
#
#   --rename            restore under `restored-<index>` instead of in place
#                       (the drill and any targeted investigation use this)
#   --indices PATTERN   which indices/data streams to restore (default: all)
#   --list              list the snapshots available in the `minio` repository
#   --yes               do not ask for confirmation
#
# In-place versus renamed
# -----------------------
# Elasticsearch refuses to restore over an OPEN index — that is a feature, not
# an obstacle: it stops a restore from silently replacing live data. So there
# are exactly two honest options, and this script implements both:
#
#   --rename   restores next to production under a new name. Nothing is lost,
#              nothing is interrupted, and the result can be compared with the
#              live index before anything is switched over. This is the default
#              answer to "did the backup work?" and to "what did this document
#              look like last Tuesday?".
#
#   in place   closes the target indices, restores, reopens. Real downtime on
#              those indices, and any document indexed since the snapshot is
#              gone. This is the answer to "we lost the cluster".
# =============================================================================
set -Eeuo pipefail
# Paths are relative to --source-path=scripts (see the lint-shell target).
# shellcheck source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=restore/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

need_manager
load_env
cd "$DW_ROOT"

readonly REPOSITORY=minio
RENAME=0
INDICES="logs-*,datalake-*"
SNAPSHOT=""
LIST=0
while (( $# )); do
  case "$1" in
    --rename)  RENAME=1; shift ;;
    --indices) INDICES="${2:?--indices needs a pattern}"; shift 2 ;;
    --list)    LIST=1; shift ;;
    --yes)     ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        die "unknown option: $1" ;;
    *)         SNAPSHOT="$1"; shift ;;
  esac
done

# Elasticsearch snapshots are not in restic: they are native snapshots in the
# `es-snapshots` bucket, driven by SLM (ADR-0008). Everything here therefore
# goes through the Elasticsearch API, not through restic.
es_cid="$(docker ps -q --filter 'label=com.docker.swarm.service.name=data_es-1' | head -1)"
[[ -n "$es_cid" ]] \
  || die "no data_es-1 task on $(hostname) — run this from the node labelled es=1"

es() {
  local method=$1 path=$2 body="${3:-}"
  if [[ -n "$body" ]]; then
    # shellcheck disable=SC2016  # $(cat …) must expand INSIDE the container
    docker exec -i "$es_cid" sh -c \
      'curl -s -u "elastic:$(cat /run/secrets/dw_es_elastic_password)" \
         -X '"$method"' -H "Content-Type: application/json" \
         "http://localhost:9200'"$path"'" -d @-' <<<"$body"
  else
    # shellcheck disable=SC2016
    docker exec "$es_cid" sh -c \
      'curl -s -u "elastic:$(cat /run/secrets/dw_es_elastic_password)" \
         -X '"$method"' "http://localhost:9200'"$path"'"'
  fi
}

# --- --list -------------------------------------------------------------------
if (( LIST )); then
  section "Snapshots in the '${REPOSITORY}' repository"
  es GET "/_snapshot/${REPOSITORY}/_all" \
    | jq -r '.snapshots[] | [.snapshot, .state, .start_time, (.indices | length | tostring) + " indices"] | @tsv' \
    | column -t
  exit 0
fi

# --- Which snapshot? ----------------------------------------------------------
if [[ -z "$SNAPSHOT" ]]; then
  SNAPSHOT="$(es GET "/_snapshot/${REPOSITORY}/_all" \
    | jq -r '[.snapshots[] | select(.state == "SUCCESS")] | last | .snapshot // empty')"
  [[ -n "$SNAPSHOT" ]] || die "no SUCCESSful snapshot in the '${REPOSITORY}' repository"
  info "no snapshot given: using the most recent successful one, ${SNAPSHOT}"
fi

state="$(es GET "/_snapshot/${REPOSITORY}/${SNAPSHOT}" | jq -r '.snapshots[0].state // "MISSING"')"
# Restoring a PARTIAL snapshot would restore an index missing shards, which
# Elasticsearch will happily do and which produces silent data loss.
[[ "$state" == "SUCCESS" ]] \
  || die "snapshot ${SNAPSHOT} is in state ${state}, not SUCCESS — refusing to restore from it"
ok "snapshot ${SNAPSHOT}: SUCCESS"

# =============================================================================
# Mode A — renamed restore, production untouched
# =============================================================================
if (( RENAME )); then
  section "Restoring ${SNAPSHOT} as restored-* (production untouched)"
  body="$(jq -n --arg idx "$INDICES" '{
    indices: $idx,
    ignore_unavailable: true,
    include_global_state: false,
    rename_pattern: "(.+)",
    rename_replacement: "restored-$1",
    include_aliases: false
  }')"
  # include_global_state:false and include_aliases:false are what keep this
  # non-destructive: restoring the global state would overwrite the live ILM
  # policies and templates, and restoring aliases would repoint production
  # traffic at the copy.
  response="$(es POST "/_snapshot/${REPOSITORY}/${SNAPSHOT}/_restore?wait_for_completion=true" "$body")"
  shards="$(jq -r '.snapshot.shards.successful // 0' <<<"$response")"
  failed="$(jq -r '.snapshot.shards.failed // 0' <<<"$response")"
  [[ "$failed" == "0" ]] || die "restore incomplete: ${failed} shard(s) failed — ${response}"
  ok "${shards} shard(s) restored under restored-*"

  section "Verification"
  es GET '/_cat/indices/restored-*?format=json&h=index,docs.count,store.size' \
    | jq -r '.[] | "    " + .index + "  " + .["docs.count"] + " docs  " + .["store.size"]'
  section "Restore complete"
  ok "the copies are named restored-*. Delete them when done:"
  ok "  curl -XDELETE .../restored-*"
  exit 0
fi

# =============================================================================
# Mode B — in-place restore
# =============================================================================
confirm "About to restore ${SNAPSHOT} IN PLACE over ${INDICES}.
Those indices will be CLOSED, replaced by their state at snapshot time, and
reopened. Every document indexed since the snapshot will be LOST.
Use --rename to restore next to production instead."

section "Closing the target indices"
# A closed index releases its shards, which is what makes the restore possible
# at all. Reopened by the restore itself on success; reopened by the trap
# below on failure, so a failed restore does not leave the platform blind.
es POST "/${INDICES}/_close?ignore_unavailable=true" >/dev/null
ok "indices closed"

reopen() {
  local rc=$?
  if (( rc != 0 )); then
    error "restore failed — reopening the indices so the cluster is not left closed"
    es POST "/${INDICES}/_open?ignore_unavailable=true" >/dev/null || true
  fi
  exit "$rc"
}
trap reopen EXIT

section "Restoring"
body="$(jq -n --arg idx "$INDICES" '{
  indices: $idx,
  ignore_unavailable: true,
  include_global_state: true
}')"
response="$(es POST "/_snapshot/${REPOSITORY}/${SNAPSHOT}/_restore?wait_for_completion=true" "$body")"
failed="$(jq -r '.snapshot.shards.failed // "?"' <<<"$response")"
[[ "$failed" == "0" ]] || die "restore incomplete: ${failed} shard(s) failed — ${response}"

es POST "/${INDICES}/_open?ignore_unavailable=true" >/dev/null
ok "indices restored and reopened"

section "Verification"
health="$(es GET '/_cluster/health' | jq -r '.status')"
[[ "$health" == "green" || "$health" == "yellow" ]] \
  || die "the cluster is ${health} after the restore — see docs/07-PRA.md, 'cluster ES rouge'"
ok "cluster health: ${health}"
es GET '/_cat/indices?format=json&h=index,health,docs.count' \
  | jq -r '.[] | "    " + .index + "  " + .health + "  " + (.["docs.count"] // "0") + " docs"'

section "Restore complete"
ok "snapshot ${SNAPSHOT} restored in place"

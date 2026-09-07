#!/usr/bin/env bash
# =============================================================================
# maint-cassandra-repair — anti-entropy repair (CDC §9.1, Sunday 05:00 UTC).
#
#   nodetool repair -pr    sequentially on cassandra-1, then 2, then 3
#
# Not a backup: a maintenance job that the backup stack schedules because it is
# the same machinery and the same failure mode — something that must happen
# every week, silently does not, and is only discovered when it matters.
#
# Why it is mandatory, not optional. The platform writes at LOCAL_QUORUM (2 of
# 3 replicas). A write acknowledged by two nodes leaves the third stale, and
# hinted handoff only covers a node that was down for less than three hours.
# Beyond that, the divergence is permanent until a repair. Worse, Cassandra's
# tombstones expire after gc_grace_seconds (10 days by default): a delete that
# has not been repaired onto every replica before that deadline can be
# RESURRECTED by the stale replica. Deleted data coming back is the failure
# this job prevents.
#
# `-pr` (primary range) repairs only the token ranges this node owns. Running
# it on all three nodes covers the ring exactly once; without `-pr`, each node
# would repair the whole ring and the work would be done three times.
#
# Sequential and never parallel: a repair is I/O and CPU heavy, and three at
# once on three 6 GB VMs sharing a disk would push the cluster into timeouts —
# an availability incident caused by the maintenance job.
# =============================================================================
set -Eeuo pipefail
# The library lives at /opt/backup/lib.sh inside the container; the directive
# below points the linter at its source in the repository.
# shellcheck source=scripts/backup/lib.sh
source /opt/backup/lib.sh

job_start maint-cassandra-repair

readonly KEYSPACE="${KEYSPACE:-datalake}"
readonly NODES=(cassandra-1 cassandra-2 cassandra-3)

JMX_PASSWORD="$(read_secret dw_cassandra_admin_password)"
readonly CRED_FILE="/tmp/.nodetool-cred"
umask 077
printf '%s %s\n' controlRole "$JMX_PASSWORD" > "$CRED_FILE"

cleanup() {
  local rc=$?
  rm -f "$CRED_FILE"
  job_end "$rc"
}
trap cleanup EXIT

failures=0
for host in "${NODES[@]}"; do
  info "=== repair -pr on ${host} ==="
  if ! wait_for "$host" 7199 60; then
    warn "${host} unreachable — skipped"
    failures=$(( failures + 1 ))
    continue
  fi

  # `-full` is NOT used: incremental repair (the default since 4.0) marks
  # repaired SSTables so the next run skips them, which is what keeps a weekly
  # repair affordable on this hardware.
  #
  # `-j 1`: one repair job at a time inside the node. The default parallelism
  # would saturate the disk of a VM that also runs Galera and Elasticsearch.
  if nodetool -h "$host" -p 7199 -u controlRole --password-file "$CRED_FILE" \
       repair -pr -j 1 "$KEYSPACE"; then
    ok "${host}: repair completed"
  else
    error "${host}: repair FAILED"
    failures=$(( failures + 1 ))
  fi
done

# A failure on one node is reported as a job failure: BackupFailed opens a GLPI
# ticket. Silently repairing two nodes out of three would leave the third
# accumulating divergence, and gc_grace_seconds would run out unnoticed.
(( failures == 0 )) || die "${failures}/${#NODES[@]} node(s) failed to repair"

ok "ring repaired on ${#NODES[@]} nodes"

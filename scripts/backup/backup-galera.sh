#!/usr/bin/env bash
# =============================================================================
# backup-galera — logical dump of every database (CDC §9.1, 02:00 UTC).
#
#   mariadb-dump → gzip → restic backup --stdin
#
# A LOGICAL dump and not a file-level copy of the datadir: Galera replicates
# synchronously, so the three data directories are equivalent — what a restore
# actually needs is a consistent, portable, human-readable SQL stream that can
# be replayed into a cluster of a different size, a different version, or a
# single node during a drill.
#
# Streamed straight into restic (`--stdin`): the dump never touches a disk, so
# the job needs no scratch volume, no temporary file to clean up on failure,
# and no free space on a node that has 6 GB of RAM and three databases.
# =============================================================================
set -Eeuo pipefail
# The library lives at /opt/backup/lib.sh inside the container; the directive
# below points the linter at its source in the repository.
# shellcheck source=scripts/backup/lib.sh
source /opt/backup/lib.sh

job_start backup-galera
restic_env
ensure_repo

readonly DB_HOST="${DB_HOST:-galera-1}"
readonly DB_USER="${DB_USER:-backup}"

wait_for "$DB_HOST" 3306 120 || die "${DB_HOST} is not reachable — is the data stack up?"

# MYSQL_PWD rather than --password=…: an argument is visible in `ps` to every
# process in the container. The client warns about MYSQL_PWD being "insecure"
# on a multi-user host; this container has one user and one process.
MYSQL_PWD="$(read_secret dw_mariadb_backup_password)"
export MYSQL_PWD

info "dumping every database from ${DB_HOST} as ${DB_USER}"

# `set -o pipefail` is what makes this safe: without it, a mariadb-dump that
# dies halfway would still produce a valid gzip stream of a TRUNCATED dump, and
# restic would archive it as a success. That is the classic way to discover, a
# year later, that every backup is half a database.
#
#   --single-transaction  consistent snapshot without locking InnoDB tables
#   --routines --events   stored procedures and scheduled events are schema too
#   --all-databases       includes `mysql`, i.e. the accounts and their grants
#   --hex-blob            binary columns survive the round trip through SQL text
mariadb-dump \
    --host="$DB_HOST" \
    --user="$DB_USER" \
    --single-transaction \
    --routines \
    --events \
    --all-databases \
    --hex-blob \
    --default-character-set=utf8mb4 \
  | gzip -6 \
  | restic backup \
      --stdin \
      --stdin-filename galera.sql.gz \
      --tag galera \
      --host dockerwarts \
      --quiet

job_size "$(restic_snapshot_size galera)"
ok "dump archived"

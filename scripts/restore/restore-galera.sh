#!/usr/bin/env bash
# =============================================================================
# restore-galera — restore the SQL databases from a restic snapshot (CDC §9.2).
#
#   scripts/restore/restore-galera.sh [options] [snapshot-id]
#
#   --fresh                re-bootstrap an EMPTY cluster before importing
#   --only-db NAME         import a single database out of the full dump
#   --as TARGET            …under a different name (used by `make dr-drill`)
#   --yes                  do not ask for confirmation (unattended)
#
# Examples
#   scripts/restore/restore-galera.sh                     # everything, latest
#   scripts/restore/restore-galera.sh 4a1b2c3d            # everything, dated
#   scripts/restore/restore-galera.sh --only-db glpi --as glpi_restore --yes
#
# The dump is `--all-databases`, so a plain restore replaces `mysql` as well:
# every account and grant comes back exactly as it was. That is what makes the
# restore complete — and what makes it destructive, hence the confirmation.
#
# --only-db/--as exist for the drill: they extract one database from the stream
# and replay it under another name, so a restore can be VERIFIED against live
# production without touching it (CDC §9.3).
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

FRESH=0
ONLY_DB=""
AS_DB=""
SNAPSHOT="latest"
while (( $# )); do
  case "$1" in
    --fresh)   FRESH=1; shift ;;
    --only-db) ONLY_DB="${2:?--only-db needs a database name}"; shift 2 ;;
    --as)      AS_DB="${2:?--as needs a database name}"; shift 2 ;;
    --yes)     ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        die "unknown option: $1" ;;
    *)         SNAPSHOT="$1"; shift ;;
  esac
done

[[ -n "$AS_DB" && -z "$ONLY_DB" ]] && die "--as requires --only-db"
[[ -z "$AS_DB" ]] && AS_DB="$ONLY_DB"

RESTORE_SECRETS+=(dw_mariadb_root_password)
SNAPSHOT="$(pick_snapshot galera "$SNAPSHOT")"

# --- 1. Optional: rebuild an empty cluster first ------------------------------
# Used when restoring onto a platform whose Galera cluster no longer exists —
# the "loss of the datacentre" scenario of docs/07-PRA.md. Importing into a
# cluster that never bootstrapped fails with a confusing wsrep error, so the
# bootstrap is done properly, by the script that knows the five steps.
if (( FRESH )); then
  confirm "About to RE-BOOTSTRAP the Galera cluster: every existing database will be lost."
  [[ -x scripts/galera-bootstrap.sh ]] || die "scripts/galera-bootstrap.sh not found"
  section "Re-bootstrapping an empty Galera cluster"
  scripts/galera-bootstrap.sh
fi

# --- 2. Sanity: is the cluster reachable and writable? ------------------------
section "Checking the target cluster"
galera_cid="$(docker ps -q --filter 'label=com.docker.swarm.service.name=data_galera-1' | head -1)"
[[ -n "$galera_cid" ]] \
  || die "no data_galera-1 task on $(hostname) — run this from the node labelled galera=1"

# `wsrep_ready` and not just "the port answers": a node performing an SST
# accepts connections and refuses every write with a misleading error.
ready="$(docker exec "$galera_cid" sh -c \
  'mariadb -u root -p"$(cat /run/secrets/dw_mariadb_root_password)" -N -B \
     -e "SHOW STATUS LIKE '"'"'wsrep_ready'"'"';" 2>/dev/null' | awk '{print $2}')"
[[ "$ready" == "ON" ]] || die "galera-1 is not ready to accept writes (wsrep_ready=${ready:-?})"
ok "galera-1 accepts writes"

# --- 3. The import ------------------------------------------------------------
if [[ -n "$ONLY_DB" ]]; then
  confirm "About to import the database '${ONLY_DB}' from snapshot ${SNAPSHOT} into '${AS_DB}'.
'${AS_DB}' will be DROPPED and recreated. Production databases are untouched."
else
  confirm "About to import the FULL dump of snapshot ${SNAPSHOT}.
Every database — including 'mysql', i.e. the accounts and grants — will be
replaced by its state at backup time. Current data will be LOST."
fi

section "Importing (snapshot ${SNAPSHOT})"

# Everything happens in ONE container: restic decrypts, gunzip decompresses and
# the MariaDB client replays, all through a pipe. The dump — which contains
# every password hash on the platform — never touches a disk.
#
# `set -o pipefail` inside the container is what makes a truncated restore fail
# loudly: without it, a restic error mid-stream would leave a partially
# imported database and report success.
# Expanded inside the container, where /run/secrets exists.
# shellcheck disable=SC2016
import_script='
  set -Eeuo pipefail
  snapshot="$1"; only_db="$2"; as_db="$3"
  export MYSQL_PWD="$(cat /run/secrets/dw_mariadb_root_password)"
  RESTIC_PASSWORD="$(cat /run/secrets/dw_restic_password)"
  AWS_ACCESS_KEY_ID="$(cat /run/secrets/dw_minio_restic_key)"
  AWS_SECRET_ACCESS_KEY="$(cat /run/secrets/dw_minio_restic_secret)"
  export RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

  if [ -z "$only_db" ]; then
    restic dump --tag galera "$snapshot" /galera.sql.gz \
      | gunzip \
      | mariadb -h galera-1 -u root
  else
    # Extract one database out of the --all-databases stream: everything from
    # its own `USE `db`;` marker up to the header of the NEXT database. The
    # header is `-- Current Database: `x``, which mariadb-dump emits before
    # each block and which therefore comes BEFORE the next USE — stopping on
    # the USE alone would let the CREATE DATABASE of the following block
    # through if the dump ever spread it over several lines.
    #
    # The DROP/CREATE/USE header is rewritten to the target name, which is what
    # lets the drill restore next to production instead of over it.
    {
      printf "DROP DATABASE IF EXISTS \140%s\140;\n" "$as_db"
      printf "CREATE DATABASE \140%s\140;\n" "$as_db"
      printf "USE \140%s\140;\n" "$as_db"
      restic dump --tag galera "$snapshot" /galera.sql.gz \
        | gunzip \
        | awk -v db="$only_db" "
            \$0 ~ \"^USE \140\" db \"\140;\" { inside = 1; next }
            inside && (/^-- Current Database:/ || /^USE \140/) { inside = 0 }
            inside && /^CREATE DATABASE/ { next }
            inside { print }
          "
    } | mariadb -h galera-1 -u root
  fi
'

if restic_run bash -c "$import_script" _ "$SNAPSHOT" "$ONLY_DB" "$AS_DB"; then
  ok "import finished"
else
  die "the import FAILED — the target database is in an unknown state. See docs/07-PRA.md."
fi

# --- 4. Verify ----------------------------------------------------------------
# A restore that is not verified is a restore nobody should trust. Counting the
# rows of the table the platform actually depends on is cheap and conclusive.
section "Verification"
check_db="${AS_DB:-glpi}"
count="$(docker exec "$galera_cid" sh -c \
  "mariadb -u root -p\"\$(cat /run/secrets/dw_mariadb_root_password)\" -N -B \
     -e 'SELECT COUNT(*) FROM \`${check_db}\`.glpi_tickets;'" 2>/dev/null || echo "")"
if [[ -n "$count" ]]; then
  ok "${check_db}.glpi_tickets: ${count} row(s)"
else
  warn "could not count ${check_db}.glpi_tickets — check the import by hand"
fi

# The grants come back with the dump, but the in-memory privilege tables do not
# reload themselves: without this, every application keeps failing to
# authenticate until the cluster is restarted.
if [[ -z "$ONLY_DB" ]]; then
  docker exec "$galera_cid" sh -c \
    'mariadb -u root -p"$(cat /run/secrets/dw_mariadb_root_password)" -e "FLUSH PRIVILEGES;"' \
    && ok "privileges reloaded"
fi

section "Restore complete"
ok "snapshot ${SNAPSHOT} restored into ${check_db}"

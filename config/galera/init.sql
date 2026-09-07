-- =============================================================================
-- MariaDB Galera — first-start initialisation (CDC §7.2).
--
-- Mounted read-only at /docker-entrypoint-initdb.d/10-dockerwarts.sql on
-- galera-1 only. The official image runs everything in that directory ONCE,
-- when the data directory is empty — so this executes exactly once, on the
-- very first start of the very first member, and Galera replicates the result
-- to galera-2 and galera-3 through their initial SST.
--
-- Passwords come from environment variables that the image expands
-- (`MARIADB_*_PASSWORD`), themselves read from Docker secrets by the
-- entrypoint. No password is ever written literally in this file.
--
-- Documented in docs/04-composants/galera.md.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Databases
-- -----------------------------------------------------------------------------
-- utf8mb4 everywhere: GLPI ticket titles contain emoji and the full accented
-- range, which MariaDB's 3-byte `utf8` truncates.
CREATE DATABASE IF NOT EXISTS glpi
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE DATABASE IF NOT EXISTS grafana
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Application accounts
--
-- Host `%` and not an IP range: overlay addresses are assigned dynamically and
-- change on every rescheduling. Confinement is done by the network
-- (`data` is `internal` and IPsec-encrypted, no port is published) rather than
-- by the grant host, which could not be kept accurate.
-- `skip_name_resolve = ON` in galera.cnf makes `%` the only workable form.
-- -----------------------------------------------------------------------------

-- GLPI: full rights on its own schema, nothing else. GLPI creates and alters
-- its own tables during installation and upgrades, hence ALL rather than a
-- narrower DML set.
CREATE USER IF NOT EXISTS 'glpi'@'%' IDENTIFIED BY '${MARIADB_GLPI_PASSWORD}';
GRANT ALL PRIVILEGES ON glpi.* TO 'glpi'@'%';

-- Grafana: same reasoning — it runs its own schema migrations at start-up.
-- This database is what makes Grafana genuinely HA in 2 replicas (ADR-0005):
-- sessions, dashboards and alert state are shared instead of local.
CREATE USER IF NOT EXISTS 'grafana'@'%' IDENTIFIED BY '${MARIADB_GRAFANA_PASSWORD}';
GRANT ALL PRIVILEGES ON grafana.* TO 'grafana'@'%';

-- -----------------------------------------------------------------------------
-- Operational accounts
-- -----------------------------------------------------------------------------

-- HAProxy health check: `option mysql-check user haproxy` opens a connection,
-- completes the handshake and disconnects. It never issues a query, so this
-- account has NO password and NO privilege beyond USAGE.
--
-- Why that is safe: USAGE grants nothing at all — the account cannot read a
-- single row. And the check must not depend on a secret, otherwise rotating
-- that secret would silently break the failover detection of the whole SQL
-- tier. This is the pattern HAProxy documents.
CREATE USER IF NOT EXISTS 'haproxy'@'%';
-- (no GRANT: USAGE is implicit and is all this account gets)

-- Prometheus mysqld-exporter: the three global-scope privileges it needs, and
-- nothing more. It reads counters, never data.
CREATE USER IF NOT EXISTS 'exporter'@'%' IDENTIFIED BY '${MARIADB_EXPORTER_PASSWORD}';
GRANT PROCESS, REPLICATION CLIENT, SLAVE MONITOR ON *.* TO 'exporter'@'%';
GRANT SELECT ON performance_schema.* TO 'exporter'@'%';
-- Cap the exporter's connections: a scrape storm must never exhaust
-- max_connections and lock GLPI out of its own database.
ALTER USER 'exporter'@'%' WITH MAX_USER_CONNECTIONS 5;

-- Backup: read-only plus LOCK TABLES, which `mariadb-dump --single-transaction`
-- needs for the non-transactional tables it may meet. No write privilege: a
-- compromised backup job must not be able to alter production data.
CREATE USER IF NOT EXISTS 'backup'@'%' IDENTIFIED BY '${MARIADB_BACKUP_PASSWORD}';
GRANT SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER, PROCESS,
      RELOAD, REPLICATION CLIENT
  ON *.* TO 'backup'@'%';
-- RELOAD is required by `--single-transaction --master-data`; PROCESS by
-- `--all-databases`; SHOW VIEW / EVENT / TRIGGER by `--routines --events`.

-- SST: used by mariabackup when a node joins and needs a full state transfer.
-- These privileges are exactly what the MariaDB documentation requires for
-- mariabackup, no more.
CREATE USER IF NOT EXISTS 'sst'@'localhost' IDENTIFIED BY '${MARIADB_SST_PASSWORD}';
GRANT RELOAD, PROCESS, LOCK TABLES, BINLOG MONITOR, REPLICA MONITOR,
      REPLICATION CLIENT, SLAVE MONITOR
  ON *.* TO 'sst'@'localhost';
-- `localhost` only: mariabackup always runs on the donor node itself, so this
-- account never needs to be reachable over the network.

-- -----------------------------------------------------------------------------
-- Clean-up of the defaults
-- -----------------------------------------------------------------------------
-- The anonymous account and the `test` database are historical MySQL defaults
-- that grant unauthenticated access. The official image already removes them,
-- but a Galera SST from an older donor could reintroduce them.
DELETE FROM mysql.global_priv WHERE User = '';
DROP DATABASE IF EXISTS test;

-- Root stays confined to localhost: administration happens through
-- `docker exec`, never over the network.
DELETE FROM mysql.global_priv WHERE User = 'root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');

FLUSH PRIVILEGES;

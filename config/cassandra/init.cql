-- =============================================================================
-- Cassandra — datalake schema (CDC §7.3).
--
-- Applied ONCE by scripts/cassandra-init.sh, which is idempotent: every
-- statement uses IF NOT EXISTS, so re-running it after a redeploy or during a
-- disaster-recovery drill is safe.
--
-- Documented in docs/04-composants/cassandra.md.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Keyspace
--
-- NetworkTopologyStrategy and not SimpleStrategy, even with a single
-- datacentre. SimpleStrategy ignores racks and datacentres; migrating away
-- from it later requires a full rebuild of every replica. Starting with NTS
-- costs nothing today and makes a second datacentre (the PRA evolution path,
-- CDC §9.5.8) a one-line ALTER.
--
-- RF=3 on a 3-node cluster: every node holds every row. Combined with
-- LOCAL_QUORUM (2 of 3), that gives RPO = 0 on the loss of one node — a write
-- acknowledged by two nodes survives the loss of any single one.
-- -----------------------------------------------------------------------------
CREATE KEYSPACE IF NOT EXISTS datalake
  WITH replication = {
    'class': 'NetworkTopologyStrategy',
    'dc1': 3
  }
  AND durable_writes = true;
-- durable_writes = true: the commit log is written before a write is
-- acknowledged. Disabling it is only sane for a keyspace that can be rebuilt
-- from elsewhere, which a datalake cannot.

-- -----------------------------------------------------------------------------
-- Table `events`
--
-- Partition key   (site, sensor_id, day)
-- Clustering key  ts DESC
--
-- Why this key, in detail — this is the single most consequential decision of
-- a Cassandra schema:
--
--   * Partitioning on (site, sensor_id, day) bounds the partition size. At the
--     demo rate of 20 events/s spread over 50 sensors, one sensor produces
--     ~35 000 rows a day, roughly 3 MB — comfortably inside the ~100 MB that
--     Cassandra handles well. Partitioning on (site, sensor_id) alone would
--     grow without limit and eventually make the partition unreadable.
--
--   * Including `day` in the PARTITION key rather than the clustering key is
--     what spreads consecutive writes across the ring instead of hammering one
--     replica set: the classic "hot partition" of time-series data.
--
--   * `ts DESC` stores the newest rows first. Every dashboard query is "the
--     last N minutes for this sensor", so the answer sits at the start of the
--     partition and Cassandra never scans past it.
--
-- The price is explicit and accepted: a query must always name site, sensor_id
-- and day. Cross-sensor and cross-day analytics go to Elasticsearch
-- (`datalake-events`), which is indexed for exactly that. The two stores are
-- complementary by design, not redundant (ADR-0007).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS datalake.events (
    site        text,
    sensor_id   text,
    day         date,
    ts          timestamp,
    temperature double,
    humidity    double,
    PRIMARY KEY ((site, sensor_id, day), ts)
) WITH CLUSTERING ORDER BY (ts DESC)
  AND default_time_to_live = 7776000
  -- 90 days, matching the `dockerwarts-logs` ILM policy so that both stores
  -- age out together. Expressed as a TTL rather than a purge job: Cassandra
  -- has no efficient DELETE, and a mass delete would create tombstones that
  -- degrade reads far more than the data itself ever did.

  AND gc_grace_seconds = 259200
  -- 3 days (default is 10). This is the window during which tombstones are
  -- kept so that a node that was down cannot "resurrect" deleted data. It MUST
  -- be longer than the interval between repairs — the weekly
  -- `maint-cassandra-repair` job runs every 7 days, so 3 days would be unsafe
  -- with deletes. It is safe HERE because rows expire by TTL rather than being
  -- deleted, and TTL expiry does not depend on the repair cycle.
  -- If a DELETE workload is ever added, raise this to 864000 (10 days).

  AND compaction = {
    'class': 'TimeWindowCompactionStrategy',
    'compaction_window_unit': 'DAYS',
    'compaction_window_size': 1
  }
  -- TWCS and not the default SizeTiered: with time-series data plus a TTL,
  -- TWCS groups each day into its own SSTable, which can then be dropped
  -- WHOLE when it expires — no compaction work, no tombstones, no read
  -- amplification. SizeTiered would keep mixing old and new data and would
  -- never be able to drop anything cheaply.

  AND comment = 'Datalake sensor events — see docs/04-composants/cassandra.md';

-- -----------------------------------------------------------------------------
-- Table `events_by_site`
--
-- A small rollup written by demo-producer alongside the raw events: one row
-- per site and minute. It answers the "events per second, per site" panel of
-- the Datalake dashboard without scanning the raw partitions.
--
-- Denormalisation is the Cassandra way: there are no joins and no secondary
-- index worth using, so a second table written at the same time as the first
-- is the correct answer to a second query pattern.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS datalake.events_by_site (
    site         text,
    day          date,
    minute       timestamp,
    event_count  counter,
    PRIMARY KEY ((site, day), minute)
) WITH CLUSTERING ORDER BY (minute DESC)
  AND compaction = {
    'class': 'TimeWindowCompactionStrategy',
    'compaction_window_unit': 'DAYS',
    'compaction_window_size': 1
  }
  AND comment = 'Per-minute event counters, per site';
-- A `counter` column cannot carry a TTL (a Cassandra restriction), so this
-- table is trimmed by the weekly maintenance job rather than by expiry. It is
-- tiny — 1440 rows per site per day — so that is not a concern.

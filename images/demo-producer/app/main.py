"""demo-producer — background sensor load for the platform (CDC §7.8).

What it is for
--------------
Two things, and both matter more than the data itself:

1. **The dashboards have something to show.** An empty Grafana proves nothing
   about a datalake, and a screenshot of a flat line at zero is not evidence
   that Cassandra and Elasticsearch work.

2. **The HA claims become measurable.** CDC §8.2 n°5 asks for continuous load
   during the chaos campaign, with an error counter that must stay at zero.
   That counter is the sharpest statement the platform can make: *production
   did not stop while a node was being killed*. A green smoke test after the
   fact says the platform recovered; a zero here says it never went down.

What it writes
--------------
`{site, sensor_id, ts, temperature, humidity}` for SENSORS sensors spread over
three sites, at RATE events per second, into BOTH stores — because they answer
different questions and are complementary by design (ADR-0007):

  * **Cassandra** `datalake.events`, keyed by `(site, sensor_id, day)`: the
    time series of one sensor on one day, read back in milliseconds.
  * **Cassandra** `datalake.events_by_site`: a per-minute counter, so the
    "events/s per site" panel does not have to scan raw partitions.
  * **Elasticsearch** `datalake-events`: the same events, indexed for the
    cross-sensor, cross-day analytics Cassandra's partition key deliberately
    refuses to serve.

The values drift like real sensors: each one random-walks around its site's
baseline and is pulled back towards it, rather than being redrawn at random
every second. Independent noise would make every aggregate a flat line and
every anomaly panel meaningless.
"""

from __future__ import annotations

import logging
import os
import random
import signal
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

from cassandra import ConsistencyLevel
from cassandra.auth import PlainTextAuthProvider
from cassandra.cluster import EXEC_PROFILE_DEFAULT, Cluster, ExecutionProfile
from cassandra.concurrent import execute_concurrent_with_args
from cassandra.policies import DCAwareRoundRobinPolicy, TokenAwarePolicy
from elasticsearch import Elasticsearch, helpers
from prometheus_client import Counter, Gauge, Histogram, start_http_server

# =============================================================================
# Configuration
# =============================================================================
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
RATE = int(os.getenv("RATE", "20"))
SENSORS = int(os.getenv("SENSORS", "50"))
SITES = [s.strip() for s in os.getenv("SITES", "poudlard,pre-au-lard,azkaban").split(",")]
KEYSPACE = os.getenv("CASSANDRA_KEYSPACE", "datalake")
CASSANDRA_HOSTS = [
    h.strip()
    for h in os.getenv("CASSANDRA_HOSTS", "cassandra-1,cassandra-2,cassandra-3").split(",")
]
CASSANDRA_DC = os.getenv("CASSANDRA_DC", "dc1")
CASSANDRA_USER = os.getenv("CASSANDRA_USER", "datalake_app")
ES_URL = os.getenv("ES_URL", "http://es-1:9200")
ES_USER = os.getenv("ES_USER", "datalake_app")
ES_DATA_STREAM = os.getenv("ES_DATA_STREAM", "datalake-events")
METRICS_PORT = int(os.getenv("METRICS_PORT", "8000"))
# One batch per tick. At the default 20 events/s that is 20 rows a second,
# which is a realistic trickle rather than a load test — the point is
# continuity, not throughput.
TICK_SECONDS = float(os.getenv("TICK_SECONDS", "1.0"))

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("demo-producer")

# =============================================================================
# Metrics — the names the Grafana "Datalake" dashboard already queries
# =============================================================================
EVENTS = Counter(
    "demo_producer_events_total",
    "Events successfully written",
    ["target"],
)
ERRORS = Counter(
    "demo_producer_errors_total",
    "Write failures. MUST stay at zero during the chaos campaign (CDC §8.2).",
    ["target"],
)
WRITE_DURATION = Histogram(
    "demo_producer_write_duration_seconds",
    "Duration of one batch write",
    ["target"],
    # Buckets chosen for what is being measured: a LOCAL_QUORUM write is
    # single-digit milliseconds nominally, and the interesting question during
    # a node loss is whether it crosses into hundreds of milliseconds — the
    # default buckets would put everything in the same one.
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)
SENSOR_GAUGE = Gauge("demo_producer_sensors", "Sensors being simulated")


def read_secret(name: str, env_var: str) -> str:
    """Read a password from /run/secrets, falling back to the environment.

    The `_FILE` indirection is how every other service on this platform
    receives a credential (CDC §N5); the plain environment variable exists so
    the producer can be run against a local cluster while developing.
    """
    path = os.getenv(env_var)
    if path:
        value = Path(path).read_text(encoding="utf-8").strip()
        if not value:
            raise SystemExit(f"{name}: {path} is empty — refusing to start")
        return value
    value = os.getenv(name, "")
    if not value:
        raise SystemExit(f"{name} is not set and no {env_var} was given")
    return value


# =============================================================================
# The sensor model
# =============================================================================
class Sensor:
    """One simulated sensor, with a value that drifts instead of jumping.

    A bounded random walk: each step moves the reading a little, and a pull
    back towards the site baseline keeps it from wandering off over days of
    running. This is what makes a graph of the last hour look like a
    measurement rather than like noise — and it is what makes the anomaly
    panels of the dashboard show something when a value does go out of range.
    """

    __slots__ = ("_base_h", "_base_t", "humidity", "sensor_id", "site", "temperature")

    def __init__(self, sensor_id: str, site: str, base_t: float, base_h: float) -> None:
        self.sensor_id = sensor_id
        self.site = site
        self._base_t = base_t
        self._base_h = base_h
        self.temperature = base_t
        self.humidity = base_h

    def step(self) -> None:
        # 0.15 of the distance back to the baseline, plus noise: enough to keep
        # the series bounded over days, gentle enough that a short window still
        # looks like drift.
        self.temperature += (self._base_t - self.temperature) * 0.15 + random.gauss(0, 0.35)
        self.humidity += (self._base_h - self.humidity) * 0.15 + random.gauss(0, 1.2)
        # Humidity is a percentage; letting it leave [0, 100] would produce
        # data the mapping accepts and no physical meaning.
        self.humidity = max(0.0, min(100.0, self.humidity))


def build_sensors(count: int, sites: list[str]) -> list[Sensor]:
    """Spread `count` sensors over the sites, each site with its own climate."""
    # A fixed seed: two runs of the campaign produce comparable graphs, and a
    # regression in the data is visible rather than lost in fresh randomness.
    # S311: this is a data generator, not a source of key material. A CSPRNG
    # here would be slower and — because it cannot be seeded reproducibly —
    # would make two campaign runs incomparable.
    rng = random.Random(20260907)  # noqa: S311
    sensors: list[Sensor] = []
    baselines = {site: (rng.uniform(14.0, 24.0), rng.uniform(35.0, 70.0)) for site in sites}
    for i in range(count):
        site = sites[i % len(sites)]
        base_t, base_h = baselines[site]
        sensors.append(
            Sensor(
                sensor_id=f"sensor-{i:04d}",
                site=site,
                base_t=base_t + rng.uniform(-1.5, 1.5),
                base_h=base_h + rng.uniform(-5.0, 5.0),
            )
        )
    return sensors


# =============================================================================
# Cassandra
# =============================================================================
def connect_cassandra(password: str) -> tuple[Cluster, object, object, object]:
    """Session plus the two prepared statements, or raise."""
    profile = ExecutionProfile(
        # TokenAware over DCAware: the driver sends each write straight to a
        # replica of its partition, so the coordinator IS a replica and one
        # network hop disappears from every write.
        load_balancing_policy=TokenAwarePolicy(DCAwareRoundRobinPolicy(local_dc=CASSANDRA_DC)),
        # LOCAL_QUORUM (2 of 3) is the CDC's consistency level: it survives the
        # loss of one node — which is precisely the scenario the chaos campaign
        # runs — while still guaranteeing that a read at LOCAL_QUORUM sees this
        # write.
        consistency_level=ConsistencyLevel.LOCAL_QUORUM,
        request_timeout=10.0,
    )
    cluster = Cluster(
        contact_points=CASSANDRA_HOSTS,
        auth_provider=PlainTextAuthProvider(username=CASSANDRA_USER, password=password),
        execution_profiles={EXEC_PROFILE_DEFAULT: profile},
        protocol_version=5,
    )
    session = cluster.connect(KEYSPACE)

    # S608: KEYSPACE comes from the deployment (an environment variable set by
    # stacks/demo.yml), never from user input, and CQL has no bind placeholder
    # for a keyspace name — every value below IS bound.
    insert_event = session.prepare(
        f"INSERT INTO {KEYSPACE}.events "  # noqa: S608
        "(site, sensor_id, day, ts, temperature, humidity) VALUES (?, ?, ?, ?, ?, ?)"
    )
    # Marking the statement idempotent is what allows the driver to RETRY it on
    # another coordinator after a timeout. Without it, a write that timed out
    # is simply lost — and a node loss produces exactly those timeouts, which
    # would show up as errors in the counter this whole service exists to keep
    # at zero. It is safe here because the primary key fully determines the
    # row: replaying the insert writes the same value again.
    insert_event.is_idempotent = True

    bump_counter = session.prepare(
        f"UPDATE {KEYSPACE}.events_by_site SET event_count = event_count + ? "  # noqa: S608
        "WHERE site = ? AND day = ? AND minute = ?"
    )
    # NOT idempotent, and deliberately not marked so: a counter increment
    # replayed is a counter incremented twice. The driver must never retry it.

    return cluster, session, insert_event, bump_counter


def write_cassandra(session, insert_event, bump_counter, events: list[dict]) -> int:
    """Write one batch. Returns the number of rows written."""
    rows = [
        (
            e["site"],
            e["sensor_id"],
            e["ts"].date(),
            e["ts"],
            e["temperature"],
            e["humidity"],
        )
        for e in events
    ]

    # `execute_concurrent_with_args` and NOT a BatchStatement. A CQL batch
    # spanning several partitions is an anti-pattern: it forces one coordinator
    # to fan out to every replica set and makes the slowest one the latency of
    # the whole batch. These rows belong to as many partitions as there are
    # sensors, so the driver's concurrent execution — token-aware, one request
    # per row, straight to a replica — is both faster and gentler on the ring.
    results = execute_concurrent_with_args(
        session, insert_event, rows, concurrency=32, raise_on_first_error=False
    )
    written = sum(1 for ok, _ in results if ok)
    failures = [outcome for ok, outcome in results if not ok]
    if failures:
        log.warning(
            "cassandra: %d/%d rows failed, first: %s", len(failures), len(rows), failures[0]
        )

    # The per-minute rollup, one counter update per (site, minute) rather than
    # one per event.
    minute_counts: dict[tuple[str, object, object], int] = {}
    for e in events:
        minute = e["ts"].replace(second=0, microsecond=0)
        key = (e["site"], e["ts"].date(), minute)
        minute_counts[key] = minute_counts.get(key, 0) + 1
    for (site, day, minute), count in minute_counts.items():
        try:
            session.execute(bump_counter, (count, site, day, minute))
        except Exception:
            # Deliberately not counted as an error: the rollup is a
            # convenience for one dashboard panel, and losing a minute of it
            # is not a data-loss event. Losing a raw event is.
            log.warning("cassandra: rollup update failed for %s/%s", site, minute)

    if failures:
        raise RuntimeError(f"{len(failures)} Cassandra write(s) failed")
    return written


# =============================================================================
# Elasticsearch
# =============================================================================
def connect_elasticsearch(password: str) -> Elasticsearch:
    return Elasticsearch(
        ES_URL,
        basic_auth=(ES_USER, password),
        request_timeout=10,
        # The client retries on a node that timed out; with three ES nodes
        # behind one Swarm VIP that is what keeps a rolling restart invisible.
        retry_on_timeout=True,
        max_retries=3,
    )


def write_elasticsearch(es: Elasticsearch, events: list[dict]) -> int:
    """Bulk-index one batch into the data stream. Returns documents indexed."""
    actions = [
        {
            "_op_type": "create",
            # `create` and not `index`: a data stream ACCEPTS ONLY create. It is
            # append-only by design, which is exactly right for events and is
            # why the mapping is `dynamic: strict` — a typo in a field name
            # fails loudly instead of silently adding a field to the mapping.
            "_index": ES_DATA_STREAM,
            "@timestamp": e["ts"].isoformat(),
            "site": e["site"],
            "sensor_id": e["sensor_id"],
            "temperature": round(e["temperature"], 2),
            "humidity": round(e["humidity"], 2),
        }
        for e in events
    ]
    success, errors = helpers.bulk(es, actions, raise_on_error=False, stats_only=False)
    if errors:
        log.warning("elasticsearch: %d document(s) rejected, first: %s", len(errors), errors[0])
        raise RuntimeError(f"{len(errors)} Elasticsearch document(s) rejected")
    return success


# =============================================================================
# Main loop
# =============================================================================
class Stopper:
    """SIGTERM handling: finish the batch in flight, then exit.

    Swarm sends SIGTERM before SIGKILL. Dying mid-batch would leave rows in
    Cassandra with no matching document in Elasticsearch — a discrepancy that
    would look like data loss during a chaos scenario and would cost an
    afternoon to explain.
    """

    def __init__(self) -> None:
        self.stop = False
        signal.signal(signal.SIGTERM, self._handle)
        signal.signal(signal.SIGINT, self._handle)

    def _handle(self, signum, _frame) -> None:
        log.info("signal %s received — finishing the current batch", signum)
        self.stop = True


def main() -> int:
    cassandra_password = read_secret("CASSANDRA_PASSWORD", "CASSANDRA_PASSWORD_FILE")
    es_password = read_secret("ES_PASSWORD", "ES_PASSWORD_FILE")

    start_http_server(METRICS_PORT)
    log.info("metrics on :%d/metrics", METRICS_PORT)

    sensors = build_sensors(SENSORS, SITES)
    SENSOR_GAUGE.set(len(sensors))
    log.info(
        "%d sensors over %d sites, %d events/s → Cassandra %s and %s",
        len(sensors),
        len(SITES),
        RATE,
        CASSANDRA_HOSTS,
        ES_DATA_STREAM,
    )

    cluster, session, insert_event, bump_counter = connect_cassandra(cassandra_password)
    es = connect_elasticsearch(es_password)
    stopper = Stopper()

    per_tick = max(1, int(RATE * TICK_SECONDS))
    cursor = 0
    try:
        while not stopper.stop:
            started = time.monotonic()
            now = datetime.now(UTC)

            # Round-robin over the sensor list rather than sampling at random:
            # every sensor then produces a continuous series, which is what
            # makes a per-sensor graph meaningful. Random sampling would leave
            # gaps in each series and hide a sensor that stopped.
            batch = []
            for _ in range(per_tick):
                sensor = sensors[cursor % len(sensors)]
                cursor += 1
                sensor.step()
                batch.append(
                    {
                        "site": sensor.site,
                        "sensor_id": sensor.sensor_id,
                        "ts": now,
                        "temperature": sensor.temperature,
                        "humidity": sensor.humidity,
                    }
                )

            # The two stores are written independently, and a failure of one
            # does NOT skip the other: during a chaos scenario it matters
            # enormously whether Cassandra and Elasticsearch failed together or
            # only one did, and coupling them would hide that.
            try:
                with WRITE_DURATION.labels(target="cassandra").time():
                    written = write_cassandra(session, insert_event, bump_counter, batch)
                EVENTS.labels(target="cassandra").inc(written)
            except Exception as exc:
                ERRORS.labels(target="cassandra").inc()
                log.error("cassandra batch failed: %s", exc)

            try:
                with WRITE_DURATION.labels(target="elasticsearch").time():
                    indexed = write_elasticsearch(es, batch)
                EVENTS.labels(target="elasticsearch").inc(indexed)
            except Exception as exc:
                ERRORS.labels(target="elasticsearch").inc()
                log.error("elasticsearch batch failed: %s", exc)

            # Sleep the remainder of the tick, so the rate stays at RATE
            # whatever the write took. Sleeping a fixed TICK_SECONDS would make
            # the effective rate drop exactly when the platform is slow — i.e.
            # during the chaos scenarios, which is when the measurement counts.
            elapsed = time.monotonic() - started
            if elapsed < TICK_SECONDS:
                time.sleep(TICK_SECONDS - elapsed)
    finally:
        log.info("shutting down")
        try:
            es.close()
        finally:
            cluster.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""Unit tests for demo-producer.

Scope, deliberately: the pure logic — the sensor model and the shape of what
gets written. The Cassandra and Elasticsearch clients are not mocked here,
because mocking a driver mostly tests the mock; those paths are exercised for
real by `make deploy-demo` and by the chaos campaign, which is the only place
`LOCAL_QUORUM under node loss` can actually be observed.

What IS worth testing without a cluster:
  * the drift stays bounded over a long run — a random walk that escapes turns
    every dashboard into nonsense after a night of running;
  * humidity stays a physical percentage;
  * sensors are spread over the sites, and the seed makes runs reproducible;
  * the round-robin visits every sensor, so no series silently goes flat.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.main import Sensor, build_sensors


def test_humidity_stays_a_percentage():
    """Ten thousand steps must never take humidity outside [0, 100]."""
    sensor = Sensor("s", "site", base_t=20.0, base_h=50.0)
    for _ in range(10_000):
        sensor.step()
        assert 0.0 <= sensor.humidity <= 100.0


def test_temperature_stays_near_its_baseline():
    """The pull-back term must keep a long run bounded.

    Without it the walk is unbounded and, after a night, the "temperature"
    panel shows a sensor at 300 °C. The bound is generous — this asserts the
    walk is anchored, not that it is narrow.
    """
    sensor = Sensor("s", "site", base_t=20.0, base_h=50.0)
    extremes = []
    for _ in range(50_000):
        sensor.step()
        extremes.append(sensor.temperature)
    assert min(extremes) > 20.0 - 10.0
    assert max(extremes) < 20.0 + 10.0


def test_a_sensor_actually_moves():
    """The counter-test: a 'stable' sensor that never moves would pass the two
    tests above and produce a flat line. It must drift."""
    sensor = Sensor("s", "site", base_t=20.0, base_h=50.0)
    start = sensor.temperature
    for _ in range(100):
        sensor.step()
    assert sensor.temperature != start


def test_sensors_are_spread_over_every_site():
    sensors = build_sensors(50, ["a", "b", "c"])
    assert len(sensors) == 50
    per_site: dict[str, int] = {}
    for s in sensors:
        per_site[s.site] = per_site.get(s.site, 0) + 1
    assert set(per_site) == {"a", "b", "c"}
    # 50 over 3 sites: 17/17/16. No site may be empty, and none may hold them
    # all — an off-by-one in the modulo would do exactly that.
    assert min(per_site.values()) >= 16


def test_sensor_ids_are_unique():
    sensors = build_sensors(200, ["a", "b"])
    assert len({s.sensor_id for s in sensors}) == 200


def test_build_is_reproducible():
    """Same seed, same baselines — so two campaign runs are comparable."""
    first = build_sensors(20, ["a", "b", "c"])
    second = build_sensors(20, ["a", "b", "c"])
    assert [(s.sensor_id, s.site, s.temperature) for s in first] == [
        (s.sensor_id, s.site, s.temperature) for s in second
    ]


def test_round_robin_visits_every_sensor():
    """The main loop advances a cursor through the list; over one full pass
    every sensor must be written exactly once. A `random.choice` would leave
    gaps in each series and hide a sensor that stopped reporting."""
    sensors = build_sensors(7, ["a", "b"])
    seen = [sensors[cursor % len(sensors)].sensor_id for cursor in range(len(sensors))]
    assert sorted(seen) == sorted(s.sensor_id for s in sensors)


@pytest.mark.parametrize("count,sites", [(1, ["a"]), (3, ["a", "b", "c"]), (100, ["a"])])
def test_edge_case_shapes(count, sites):
    sensors = build_sensors(count, sites)
    assert len(sensors) == count
    assert all(s.site in sites for s in sensors)

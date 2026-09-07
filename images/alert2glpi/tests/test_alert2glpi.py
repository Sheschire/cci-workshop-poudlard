"""Unit tests for alert2glpi (CDC §7.6, ADR-0009).

The GLPI API is mocked with ``respx``, which intercepts at the httpx transport
layer. That matters: the tests exercise the REAL client code — the headers it
sends, the JSON it builds, how it reads the responses — instead of a
hand-written stub that would only prove the stub works.

What is asserted, in order of importance:

1. a firing alert creates a ticket with the right title, priority and content;
2. a SECOND firing of the same alert creates NOTHING (deduplication) — this is
   the behaviour that keeps a 4-hourly repeat from producing six tickets a day;
3. a resolved alert adds a follow-up and sets the status to Résolu — the half
   of the loop that is usually missing;
4. a GLPI outage returns 503 (so Alertmanager retries) and never loses an alert
   silently;
5. one failing alert does not abort the rest of the batch.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import httpx
import pytest
import respx

# Import the application with the secrets supplied through the environment,
# exactly as the container does through config/common/secrets-entrypoint.sh.
os.environ.setdefault("GLPI_APP_TOKEN", "test-app-token")
os.environ.setdefault("GLPI_USER_TOKEN", "test-user-token")
os.environ.setdefault("GLPI_URL", "http://glpi-test/apirest.php")
os.environ.setdefault("GRAFANA_URL", "https://grafana.test")

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import main as a2g

GLPI = "http://glpi-test/apirest.php"


# =============================================================================
# Fixtures
# =============================================================================
@pytest.fixture(autouse=True)
def reset_metrics():
    """Counters are module-level: reset them so tests stay independent."""
    for key in a2g.METRICS:
        a2g.METRICS[key] = 0
    yield


@pytest.fixture
def firing_alert() -> dict:
    return {
        "status": "firing",
        "labels": {
            "alertname": "GLPIDown",
            "severity": "critical",
            "component": "glpi",
            "instance": "https://glpi.dockerwarts.lan/",
        },
        "annotations": {
            "summary": "GLPI indisponible",
            "description": "La sonde HTTP échoue depuis 1 minute.",
            "runbook": "https://example.test/runbook",
            "dashboard": "https://grafana.test/d/dw-overview",
        },
        "startsAt": "2026-09-07T10:00:00Z",
        "endsAt": "0001-01-01T00:00:00Z",
        "generatorURL": "http://prometheus:9090/graph?g0.expr=probe_success",
        "fingerprint": "a1b2c3d4e5f6a7b8",
    }


@pytest.fixture
def resolved_alert(firing_alert: dict) -> dict:
    resolved = dict(firing_alert)
    resolved["status"] = "resolved"
    resolved["endsAt"] = "2026-09-07T10:15:00Z"
    return resolved


def webhook(*alerts: dict) -> dict:
    """A minimal Alertmanager v4 payload."""
    return {
        "version": "4",
        "groupKey": '{}:{alertname="GLPIDown"}',
        "status": alerts[0]["status"],
        "receiver": "glpi",
        "alerts": list(alerts),
    }


def mock_session_and_category(router: respx.Router, *, category_id: int | None = 7) -> None:
    """The two calls every batch makes before touching any ticket."""
    router.get(f"{GLPI}/initSession").mock(
        return_value=httpx.Response(200, json={"session_token": "sess-123"})
    )
    router.get(f"{GLPI}/killSession").mock(return_value=httpx.Response(200, json={}))
    body = {"data": [{"2": category_id}], "totalcount": 1} if category_id else {"data": []}
    router.get(f"{GLPI}/search/ITILCategory").mock(return_value=httpx.Response(200, json=body))


async def post_alert(payload: dict):
    """Call the endpoint with a real Request object, no TestClient needed."""
    from fastapi import Request

    body = __import__("json").dumps(payload).encode()

    async def receive():
        return {"type": "http.request", "body": body, "more_body": False}

    scope = {
        "type": "http",
        "method": "POST",
        "path": "/alert",
        "headers": [(b"content-type", b"application/json")],
        "app": a2g.app,
        "query_string": b"",
    }
    request = Request(scope, receive)
    # `lifespan` normally sets these; set them directly for the unit tests.
    a2g.app.state.app_token = "test-app-token"
    a2g.app.state.user_token = "test-user-token"
    a2g.app.state.category_id = None
    return await a2g.alert(request)


# =============================================================================
# 1. Ticket rendering — pure functions, no I/O
# =============================================================================
def test_title_carries_the_fingerprint(firing_alert):
    title = a2g.build_title(firing_alert)
    assert title.startswith("[critical] GLPIDown — ")
    # The fingerprint in the title IS the deduplication key: without it,
    # find_open_ticket has nothing to search on.
    assert "[AM:a1b2c3d4e5f6a7b8]" in title


def test_title_prefers_node_then_service_then_instance():
    base = {"labels": {"alertname": "X", "severity": "warning"}, "fingerprint": "f"}
    assert "— —" in a2g.build_title(base)

    with_instance = {**base, "labels": {**base["labels"], "instance": "i"}}
    assert "— i " in a2g.build_title(with_instance)

    with_service = {**with_instance, "labels": {**with_instance["labels"], "service": "s"}}
    assert "— s " in a2g.build_title(with_service)

    with_node = {**with_service, "labels": {**with_service["labels"], "node": "node1"}}
    assert "— node1 " in a2g.build_title(with_node)


def test_content_includes_every_label_and_link(firing_alert):
    content = a2g.build_content(firing_alert)
    assert "GLPI indisponible" in content
    assert "La sonde HTTP échoue" in content
    for key in firing_alert["labels"]:
        assert key in content
    assert "https://example.test/runbook" in content
    assert "https://grafana.test/d/dw-overview" in content
    assert "http://prometheus:9090/graph" in content
    # A firing alert has the sentinel endsAt: it must not be shown as a real
    # end time, which would be confusing in the ticket.
    assert "0001-01-01" not in content


def test_severity_maps_to_glpi_priority():
    for severity, expected in (("critical", 5), ("warning", 3), ("info", 2)):
        alert = {"labels": {"alertname": "A", "severity": severity}, "fingerprint": "f"}
        fields = a2g.build_ticket_fields(alert, None)
        assert fields["priority"] == expected
        assert fields["urgency"] == expected
        assert fields["impact"] == expected

    unknown = {"labels": {"alertname": "A", "severity": "weird"}, "fingerprint": "f"}
    assert a2g.build_ticket_fields(unknown, None)["priority"] == a2g.DEFAULT_PRIORITY


def test_title_is_truncated_to_the_glpi_column_size():
    alert = {
        "labels": {"alertname": "A" * 400, "severity": "warning", "node": "n"},
        "fingerprint": "f",
    }
    # GLPI truncates past 255 SILENTLY, which would corrupt the fingerprint at
    # the end of the title and break deduplication forever.
    assert len(a2g.build_ticket_fields(alert, None)["name"]) <= 255


# =============================================================================
# 2. Firing — creation
# =============================================================================
@respx.mock
async def test_firing_creates_a_ticket(firing_alert):
    mock_session_and_category(respx.mock)
    # No open ticket yet.
    search = respx.get(f"{GLPI}/search/Ticket").mock(
        return_value=httpx.Response(200, json={"data": [], "totalcount": 0})
    )
    create = respx.post(f"{GLPI}/Ticket").mock(
        return_value=httpx.Response(201, json={"id": 42, "message": ""})
    )

    response = await post_alert(webhook(firing_alert))

    assert response.status_code == 200
    import json

    body = json.loads(response.body)
    assert body["created"] == 1
    assert body["deduplicated"] == 0
    assert search.called and create.called

    sent = json.loads(create.calls[0].request.content)["input"]
    assert "[AM:a1b2c3d4e5f6a7b8]" in sent["name"]
    assert sent["priority"] == 5
    assert sent["type"] == 1
    assert sent["itilcategories_id"] == 7
    assert a2g.METRICS["alert2glpi_tickets_created_total"] == 1


@respx.mock
async def test_the_session_token_is_sent_on_every_call(firing_alert):
    mock_session_and_category(respx.mock)
    respx.get(f"{GLPI}/search/Ticket").mock(return_value=httpx.Response(200, json={"data": []}))
    create = respx.post(f"{GLPI}/Ticket").mock(return_value=httpx.Response(201, json={"id": 1}))

    await post_alert(webhook(firing_alert))

    headers = create.calls[0].request.headers
    assert headers["session-token"] == "sess-123"
    assert headers["app-token"] == "test-app-token"


@respx.mock
async def test_the_session_is_always_closed(firing_alert):
    mock_session_and_category(respx.mock)
    respx.get(f"{GLPI}/search/Ticket").mock(return_value=httpx.Response(200, json={"data": []}))
    respx.post(f"{GLPI}/Ticket").mock(return_value=httpx.Response(201, json={"id": 1}))

    await post_alert(webhook(firing_alert))

    # A leaked session counts against GLPI's concurrent-session limit and would
    # eventually make initSession fail for everyone.
    assert respx.calls.last is not None
    killed = [c for c in respx.calls if c.request.url.path.endswith("/killSession")]
    assert len(killed) == 1


# =============================================================================
# 3. Deduplication — the behaviour that keeps the ticket queue usable
# =============================================================================
@respx.mock
async def test_second_firing_creates_nothing(firing_alert):
    mock_session_and_category(respx.mock)
    # An open ticket already carries this fingerprint.
    respx.get(f"{GLPI}/search/Ticket").mock(
        return_value=httpx.Response(200, json={"data": [{"2": 42}], "totalcount": 1})
    )
    create = respx.post(f"{GLPI}/Ticket").mock(return_value=httpx.Response(201, json={"id": 99}))

    response = await post_alert(webhook(firing_alert))

    import json

    body = json.loads(response.body)
    assert body["created"] == 0
    assert body["deduplicated"] == 1
    # THE assertion of this test: no ticket was created.
    assert not create.called
    assert a2g.METRICS["alert2glpi_tickets_deduplicated_total"] == 1


@respx.mock
async def test_the_search_only_matches_open_tickets(firing_alert):
    mock_session_and_category(respx.mock)
    search = respx.get(f"{GLPI}/search/Ticket").mock(
        return_value=httpx.Response(200, json={"data": []})
    )
    respx.post(f"{GLPI}/Ticket").mock(return_value=httpx.Response(201, json={"id": 1}))

    await post_alert(webhook(firing_alert))

    params = search.calls[0].request.url.params
    assert params["criteria[0][value]"] == "[AM:a1b2c3d4e5f6a7b8]"
    # status < 5 = new/assigned/planned/pending. Without this, a recurring
    # incident would reopen an archived ticket instead of raising a new one.
    assert params["criteria[1][field]"] == "12"
    assert params["criteria[1][searchtype]"] == "lessthan"
    assert params["criteria[1][value]"] == "5"


@respx.mock
async def test_a_206_partial_content_search_is_accepted(firing_alert):
    """GLPI answers 206 to a ranged search; treating it as an error would make
    deduplication silently stop working and produce a ticket every repeat."""
    mock_session_and_category(respx.mock)
    respx.get(f"{GLPI}/search/Ticket").mock(
        return_value=httpx.Response(206, json={"data": [{"2": 42}], "totalcount": 1})
    )
    create = respx.post(f"{GLPI}/Ticket").mock(return_value=httpx.Response(201, json={"id": 99}))

    await post_alert(webhook(firing_alert))
    assert not create.called


# =============================================================================
# 4. Resolution — the half of the loop that is usually missing
# =============================================================================
@respx.mock
async def test_resolved_adds_a_followup_and_solves(resolved_alert):
    mock_session_and_category(respx.mock)
    respx.get(f"{GLPI}/search/Ticket").mock(
        return_value=httpx.Response(200, json={"data": [{"2": 42}], "totalcount": 1})
    )
    followup = respx.post(f"{GLPI}/Ticket/42/ITILFollowup").mock(
        return_value=httpx.Response(201, json={"id": 5})
    )
    update = respx.put(f"{GLPI}/Ticket/42").mock(
        return_value=httpx.Response(200, json={"42": True})
    )

    response = await post_alert(webhook(resolved_alert))

    import json

    assert json.loads(response.body)["resolved"] == 1
    assert followup.called and update.called

    body = json.loads(followup.calls[0].request.content)["input"]
    assert "résolue automatiquement" in body["content"]
    assert "2026-09-07T10:15:00Z" in body["content"]

    assert json.loads(update.calls[0].request.content)["input"]["status"] == a2g.STATUS_SOLVED


@respx.mock
async def test_resolved_without_a_ticket_is_not_an_error(resolved_alert):
    """alert2glpi may have been down when the alert fired, or a human may have
    closed the ticket. Neither is a failure."""
    mock_session_and_category(respx.mock)
    respx.get(f"{GLPI}/search/Ticket").mock(return_value=httpx.Response(200, json={"data": []}))

    response = await post_alert(webhook(resolved_alert))

    import json

    body = json.loads(response.body)
    assert response.status_code == 200
    assert body["resolved"] == 0
    assert body["errors"] == 0


# =============================================================================
# 5. Failure modes
# =============================================================================
@respx.mock
async def test_glpi_unreachable_returns_503(firing_alert):
    """503 and not 500: Alertmanager retries a 5xx, and this failure is
    transient by nature. Returning 200 would DROP the alert."""
    respx.get(f"{GLPI}/initSession").mock(side_effect=httpx.ConnectError("refused"))

    response = await post_alert(webhook(firing_alert))

    assert response.status_code == 503
    assert a2g.METRICS["alert2glpi_api_errors_total"] == 1


@respx.mock
async def test_one_failing_alert_does_not_abort_the_batch(firing_alert):
    mock_session_and_category(respx.mock)
    second = {**firing_alert, "fingerprint": "second-fingerprint"}

    respx.get(f"{GLPI}/search/Ticket").mock(return_value=httpx.Response(200, json={"data": []}))
    # The first creation fails, the second succeeds.
    respx.post(f"{GLPI}/Ticket").mock(
        side_effect=[
            httpx.Response(500, json={"error": "boom"}),
            httpx.Response(201, json={"id": 43}),
        ]
    )

    response = await post_alert(webhook(firing_alert, second))

    import json

    body = json.loads(response.body)
    assert body["errors"] == 1
    assert body["created"] == 1  # the second one went through


async def test_an_alert_without_a_fingerprint_is_skipped():
    """No fingerprint means no deduplication key: creating a ticket anyway
    would produce a new one on every repeat, forever."""
    with respx.mock:
        mock_session_and_category(respx.mock)
        create = respx.post(f"{GLPI}/Ticket").mock(return_value=httpx.Response(201, json={"id": 1}))
        no_fp = {"status": "firing", "labels": {"alertname": "X"}, "annotations": {}}

        response = await post_alert(webhook(no_fp))

        import json

        assert json.loads(response.body)["created"] == 0
        assert not create.called


async def test_invalid_json_returns_400():
    from fastapi import Request

    async def receive():
        return {"type": "http.request", "body": b"not json", "more_body": False}

    request = Request(
        {
            "type": "http",
            "method": "POST",
            "path": "/alert",
            "headers": [(b"content-type", b"application/json")],
            "app": a2g.app,
            "query_string": b"",
        },
        receive,
    )
    response = await a2g.alert(request)
    assert response.status_code == 400


async def test_empty_batch_is_accepted():
    response = await post_alert({"version": "4", "alerts": []})
    import json

    assert response.status_code == 200
    assert json.loads(response.body)["processed"] == 0


# =============================================================================
# 6. Secrets and endpoints
# =============================================================================
def test_read_secret_prefers_the_file(tmp_path):
    secret = tmp_path / "token"
    secret.write_text("  from-file  \n")
    os.environ["TEST_SECRET"] = "from-env"
    os.environ["TEST_SECRET_FILE"] = str(secret)
    try:
        assert a2g._read_secret("TEST_SECRET") == "from-file"
    finally:
        del os.environ["TEST_SECRET"], os.environ["TEST_SECRET_FILE"]


def test_read_secret_refuses_an_empty_value(tmp_path):
    """A mounted-but-empty secret means the generation step failed. Starting
    anyway would produce an authentication loop that looks like a GLPI bug."""
    empty = tmp_path / "empty"
    empty.write_text("")
    os.environ["TEST_EMPTY_FILE"] = str(empty)
    try:
        with pytest.raises(SystemExit):
            a2g._read_secret("TEST_EMPTY")
    finally:
        del os.environ["TEST_EMPTY_FILE"]


async def test_metrics_endpoint_is_valid_prometheus_text():
    a2g.METRICS["alert2glpi_tickets_created_total"] = 3
    response = await a2g.metrics()
    text = response.body.decode()
    assert "# HELP alert2glpi_tickets_created_total" in text
    assert "# TYPE alert2glpi_tickets_created_total counter" in text
    assert "alert2glpi_tickets_created_total 3" in text
    # Every declared metric must be rendered, or a dashboard panel silently
    # shows "No data".
    for name in a2g.METRICS:
        assert f"# TYPE {name} " in text


async def test_healthz_does_not_call_glpi():
    """A GLPI outage must not restart alert2glpi in a loop: the restarts would
    destroy the in-memory metrics exactly when they are needed."""
    with respx.mock:
        route = respx.get(f"{GLPI}/initSession").mock(
            return_value=httpx.Response(200, json={"session_token": "x"})
        )
        assert await a2g.healthz() == {"status": "ok"}
        assert not route.called

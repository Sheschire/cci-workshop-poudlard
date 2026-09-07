"""alert2glpi — turn Alertmanager webhooks into GLPI tickets.

ADR-0009. This is what closes the incident loop: an alert that does not become
a ticket is an alert nobody owns.

Behaviour
---------
``POST /alert`` receives an Alertmanager v4 webhook. For each alert:

* **firing** — look for an open ticket whose title contains
  ``[AM:<fingerprint>]``. Create one if there is none, do nothing if there is.
  The fingerprint is Alertmanager's own stable hash of the alert labels, so the
  same alert always maps to the same ticket, across restarts of either side.
* **resolved** — add a follow-up and set the ticket to *Résolu* (status 5).

Why deduplicate on the fingerprint rather than on the title
-----------------------------------------------------------
Alertmanager re-sends a firing alert every ``repeat_interval`` (4 h here).
Without deduplication that is a new ticket every four hours for the same
incident. Matching on the summary text would also merge two genuinely different
alerts that happen to share a summary — the fingerprint cannot.

The GLPI session
----------------
GLPI's REST API is session-based: ``initSession`` returns a token that every
later call must carry, and sessions are a limited resource. So one session is
opened per *request batch* and closed in a ``finally`` — never one per alert,
and never a long-lived one that would expire silently mid-incident.
"""

from __future__ import annotations

import logging
import os
import sys
import time
from contextlib import asynccontextmanager
from typing import Any

import httpx
from fastapi import FastAPI, Request, Response, status
from fastapi.responses import JSONResponse

# =============================================================================
# Configuration
# =============================================================================


def _read_secret(name: str, *, required: bool = True) -> str:
    """Read a value from ``<NAME>_FILE`` (a Docker secret) or ``<NAME>``.

    An empty value is treated as absent: a mounted-but-empty secret means the
    generation step failed, and starting with an empty token would produce an
    authentication loop that looks like a GLPI problem.
    """
    path = os.environ.get(f"{name}_FILE", "").strip()
    value = ""
    if path:
        try:
            with open(path, encoding="utf-8") as handle:
                value = handle.read().strip()
        except OSError as exc:
            if required:
                raise SystemExit(f"{name}_FILE={path} is unreadable: {exc}") from exc
    else:
        value = os.environ.get(name, "").strip()

    if required and not value:
        raise SystemExit(f"{name} (or {name}_FILE) is unset or empty")
    return value


GLPI_URL = os.environ.get("GLPI_URL", "http://glpi-web/apirest.php").rstrip("/")
GRAFANA_URL = os.environ.get("GRAFANA_URL", "").rstrip("/")
HTTP_TIMEOUT = float(os.environ.get("HTTP_TIMEOUT", "15"))
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()

# GLPI priority scale: 1 très basse … 5 très haute.
SEVERITY_TO_PRIORITY = {"critical": 5, "warning": 3, "info": 2}
DEFAULT_PRIORITY = 3

# GLPI ticket statuses.
STATUS_SOLVED = 5

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format='{"ts":"%(asctime)s","level":"%(levelname)s","msg":"%(message)s"}',
    stream=sys.stdout,
)
log = logging.getLogger("alert2glpi")

# =============================================================================
# Metrics — plain counters, rendered by hand.
#
# A Prometheus client library would be a dependency for four counters, and the
# text format is trivial. This also keeps /metrics free of the ~40 default
# process/GC series that nobody looks at.
# =============================================================================
METRICS: dict[str, float] = {
    "alert2glpi_tickets_created_total": 0,
    "alert2glpi_tickets_resolved_total": 0,
    "alert2glpi_tickets_deduplicated_total": 0,
    "alert2glpi_api_errors_total": 0,
    "alert2glpi_webhooks_received_total": 0,
    "alert2glpi_last_success_timestamp": 0,
}

METRIC_HELP = {
    "alert2glpi_tickets_created_total": ("counter", "Tickets GLPI créés"),
    "alert2glpi_tickets_resolved_total": ("counter", "Tickets GLPI passés en résolu"),
    "alert2glpi_tickets_deduplicated_total": (
        "counter",
        "Alertes reçues pour lesquelles un ticket ouvert existait déjà",
    ),
    "alert2glpi_api_errors_total": ("counter", "Erreurs de l'API GLPI"),
    "alert2glpi_webhooks_received_total": ("counter", "Webhooks Alertmanager reçus"),
    "alert2glpi_last_success_timestamp": (
        "gauge",
        "Horodatage du dernier traitement complet réussi",
    ),
}


# =============================================================================
# GLPI client
# =============================================================================
class GlpiClient:
    """Minimal GLPI REST client: session, search, create, follow-up, update."""

    def __init__(self, base_url: str, app_token: str, user_token: str) -> None:
        self.base_url = base_url
        self.app_token = app_token
        self.user_token = user_token
        self.session_token: str | None = None
        self._client = httpx.AsyncClient(timeout=HTTP_TIMEOUT)

    # --- session ------------------------------------------------------------
    async def init_session(self) -> None:
        response = await self._client.get(
            f"{self.base_url}/initSession",
            headers={
                "Content-Type": "application/json",
                "App-Token": self.app_token,
                "Authorization": f"user_token {self.user_token}",
            },
        )
        response.raise_for_status()
        self.session_token = response.json()["session_token"]

    async def kill_session(self) -> None:
        """Close the session. Never raises: this runs in a ``finally``."""
        if not self.session_token:
            return
        try:
            await self._client.get(f"{self.base_url}/killSession", headers=self._headers())
        except (httpx.HTTPError, KeyError):
            log.warning("killSession failed; the session will expire on its own")
        finally:
            self.session_token = None

    def _headers(self) -> dict[str, str]:
        return {
            "Content-Type": "application/json",
            "App-Token": self.app_token,
            "Session-Token": self.session_token or "",
        }

    async def aclose(self) -> None:
        await self._client.aclose()

    # --- operations ---------------------------------------------------------
    async def find_open_ticket(self, fingerprint: str) -> int | None:
        """Return the id of an OPEN ticket carrying this fingerprint, if any.

        ``criteria[1]`` restricts to statuses 1-4 (new, assigned, planned,
        pending): a ticket already solved or closed must NOT be reused, or a
        recurring incident would silently reopen an archived ticket instead of
        raising a new one.
        """
        params = {
            "criteria[0][field]": "1",  # ticket title
            "criteria[0][searchtype]": "contains",
            "criteria[0][value]": f"[AM:{fingerprint}]",
            "criteria[1][link]": "AND",
            "criteria[1][field]": "12",  # status
            "criteria[1][searchtype]": "lessthan",
            "criteria[1][value]": "5",
            "forcedisplay[0]": "2",  # the id column
            "range": "0-1",
        }
        response = await self._client.get(
            f"{self.base_url}/search/Ticket", headers=self._headers(), params=params
        )
        # 206 Partial Content is GLPI's normal answer to a ranged search.
        if response.status_code not in (200, 206):
            return None
        payload = response.json()
        rows = payload.get("data") or []
        if not rows:
            return None
        first = rows[0]
        # GLPI returns the columns keyed by their numeric id.
        return int(first.get("2") or first.get(2))

    async def create_ticket(self, fields: dict[str, Any]) -> int:
        response = await self._client.post(
            f"{self.base_url}/Ticket", headers=self._headers(), json={"input": fields}
        )
        response.raise_for_status()
        payload = response.json()
        if isinstance(payload, list):
            payload = payload[0]
        return int(payload["id"])

    async def add_followup(self, ticket_id: int, content: str) -> None:
        response = await self._client.post(
            f"{self.base_url}/Ticket/{ticket_id}/ITILFollowup",
            headers=self._headers(),
            json={"input": {"itemtype": "Ticket", "items_id": ticket_id, "content": content}},
        )
        response.raise_for_status()

    async def set_status(self, ticket_id: int, new_status: int) -> None:
        response = await self._client.put(
            f"{self.base_url}/Ticket/{ticket_id}",
            headers=self._headers(),
            json={"input": {"id": ticket_id, "status": new_status}},
        )
        response.raise_for_status()

    async def find_category(self, name: str) -> int | None:
        response = await self._client.get(
            f"{self.base_url}/search/ITILCategory",
            headers=self._headers(),
            params={
                "criteria[0][field]": "1",
                "criteria[0][searchtype]": "equals",
                "criteria[0][value]": name,
                "forcedisplay[0]": "2",
                "range": "0-1",
            },
        )
        if response.status_code not in (200, 206):
            return None
        rows = (response.json() or {}).get("data") or []
        if not rows:
            return None
        return int(rows[0].get("2") or rows[0].get(2))


# =============================================================================
# Ticket rendering
# =============================================================================
def build_title(alert: dict[str, Any]) -> str:
    """``[severity] AlertName — target [AM:fingerprint]``.

    The fingerprint goes in the TITLE and not in a custom field: GLPI's search
    API can filter on the title with a plain `contains`, with no plugin and no
    schema change, which keeps the deduplication working on a stock GLPI.
    """
    labels = alert.get("labels") or {}
    severity = labels.get("severity", "unknown")
    alertname = labels.get("alertname", "UnknownAlert")
    target = labels.get("node") or labels.get("service") or labels.get("instance") or "—"
    fingerprint = alert.get("fingerprint", "unknown")
    return f"[{severity}] {alertname} — {target} [AM:{fingerprint}]"


def build_content(alert: dict[str, Any]) -> str:
    """The ticket body: summary, description, every label, and the links."""
    labels = alert.get("labels") or {}
    annotations = alert.get("annotations") or {}

    lines = [
        annotations.get("summary", "(pas de résumé)"),
        "",
        annotations.get("description", ""),
        "",
        "--- Étiquettes ---",
    ]
    lines.extend(f"{key} = {value}" for key, value in sorted(labels.items()))

    lines += ["", "--- Horodatage ---", f"Début : {alert.get('startsAt', '?')}"]
    if alert.get("endsAt") and not alert["endsAt"].startswith("0001-01-01"):
        lines.append(f"Fin   : {alert['endsAt']}")

    links = []
    if annotations.get("runbook"):
        links.append(f"Runbook   : {annotations['runbook']}")
    if annotations.get("dashboard"):
        links.append(f"Dashboard : {annotations['dashboard']}")
    elif GRAFANA_URL:
        links.append(f"Grafana   : {GRAFANA_URL}")
    if alert.get("generatorURL"):
        links.append(f"Prometheus: {alert['generatorURL']}")
    if links:
        lines += ["", "--- Liens ---", *links]

    return "\n".join(lines)


def build_ticket_fields(alert: dict[str, Any], category_id: int | None) -> dict[str, Any]:
    labels = alert.get("labels") or {}
    severity = labels.get("severity", "warning")
    fields: dict[str, Any] = {
        "name": build_title(alert)[:255],  # GLPI truncates silently past 255
        "content": build_content(alert),
        "type": 1,  # Incident (2 would be Request)
        "urgency": SEVERITY_TO_PRIORITY.get(severity, DEFAULT_PRIORITY),
        "impact": SEVERITY_TO_PRIORITY.get(severity, DEFAULT_PRIORITY),
        "priority": SEVERITY_TO_PRIORITY.get(severity, DEFAULT_PRIORITY),
        "status": 1,  # Nouveau
    }
    if category_id is not None:
        fields["itilcategories_id"] = category_id
    return fields


# =============================================================================
# Application
# =============================================================================
@asynccontextmanager
async def lifespan(_: FastAPI):
    """Read the secrets once, at start-up, and fail fast if they are missing."""
    app.state.app_token = _read_secret("GLPI_APP_TOKEN")
    app.state.user_token = _read_secret("GLPI_USER_TOKEN")
    app.state.category_id = None
    log.info("alert2glpi started, GLPI at %s", GLPI_URL)
    yield


app = FastAPI(title="alert2glpi", version="1.0.0", lifespan=lifespan)


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    """Liveness only.

    Deliberately does NOT call GLPI: a GLPI outage would then restart
    alert2glpi in a loop, and the restarts would destroy the in-memory metrics
    just when they are needed. GLPI's own availability is measured by the
    blackbox probe.
    """
    return {"status": "ok"}


@app.get("/metrics")
async def metrics() -> Response:
    body = []
    for name, value in METRICS.items():
        kind, help_text = METRIC_HELP[name]
        body.append(f"# HELP {name} {help_text}")
        body.append(f"# TYPE {name} {kind}")
        body.append(f"{name} {value}")
    return Response("\n".join(body) + "\n", media_type="text/plain; version=0.0.4")


@app.post("/alert")
async def alert(request: Request) -> JSONResponse:
    """Handle one Alertmanager webhook batch."""
    METRICS["alert2glpi_webhooks_received_total"] += 1

    try:
        payload = await request.json()
    except ValueError:
        return JSONResponse({"error": "invalid JSON"}, status_code=status.HTTP_400_BAD_REQUEST)

    alerts = payload.get("alerts") or []
    if not alerts:
        return JSONResponse({"processed": 0, "detail": "no alert in the payload"})

    client = GlpiClient(GLPI_URL, request.app.state.app_token, request.app.state.user_token)
    created = resolved = deduplicated = errors = 0

    try:
        await client.init_session()

        # Looked up once per batch and cached for the lifetime of the process:
        # the category never changes, and a lookup per alert would triple the
        # API calls during an alert storm — exactly when GLPI is least able to
        # absorb them.
        if request.app.state.category_id is None:
            request.app.state.category_id = await client.find_category("Infrastructure")

        for one in alerts:
            fingerprint = one.get("fingerprint")
            if not fingerprint:
                log.warning("alert without a fingerprint, ignored: %s", one.get("labels"))
                continue

            try:
                if one.get("status") == "resolved":
                    resolved += await _handle_resolved(client, one, fingerprint)
                else:
                    was_created, was_dedup = await _handle_firing(
                        client, one, fingerprint, request.app.state.category_id
                    )
                    created += was_created
                    deduplicated += was_dedup
            except httpx.HTTPError as exc:
                # One failing alert must not abort the whole batch: the others
                # may be more important than this one.
                errors += 1
                METRICS["alert2glpi_api_errors_total"] += 1
                log.error("GLPI API error on %s: %s", fingerprint, exc)

        METRICS["alert2glpi_last_success_timestamp"] = time.time()

    except httpx.HTTPError as exc:
        METRICS["alert2glpi_api_errors_total"] += 1
        log.error("cannot open a GLPI session: %s", exc)
        # 503 and not 500: Alertmanager retries a 5xx, and this failure is
        # transient by nature (GLPI restarting, database failing over).
        return JSONResponse(
            {"error": "GLPI unreachable", "detail": str(exc)},
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        )
    finally:
        await client.kill_session()
        await client.aclose()

    log.info(
        "batch handled: %d created, %d resolved, %d deduplicated, %d errors",
        created,
        resolved,
        deduplicated,
        errors,
    )
    return JSONResponse(
        {
            "processed": len(alerts),
            "created": created,
            "resolved": resolved,
            "deduplicated": deduplicated,
            "errors": errors,
        }
    )


async def _handle_firing(
    client: GlpiClient, one: dict[str, Any], fingerprint: str, category_id: int | None
) -> tuple[int, int]:
    """Create a ticket unless an open one already carries this fingerprint."""
    existing = await client.find_open_ticket(fingerprint)
    if existing is not None:
        METRICS["alert2glpi_tickets_deduplicated_total"] += 1
        log.info("alert %s already has the open ticket #%d", fingerprint, existing)
        return 0, 1

    ticket_id = await client.create_ticket(build_ticket_fields(one, category_id))
    METRICS["alert2glpi_tickets_created_total"] += 1
    log.info("ticket #%d created for %s", ticket_id, fingerprint)
    return 1, 0


async def _handle_resolved(client: GlpiClient, one: dict[str, Any], fingerprint: str) -> int:
    """Add a follow-up and set the ticket to Résolu."""
    ticket_id = await client.find_open_ticket(fingerprint)
    if ticket_id is None:
        # Normal, not an error: alert2glpi may have been down when the alert
        # fired, or the ticket may already have been closed by a human.
        log.info("no open ticket for the resolved alert %s", fingerprint)
        return 0

    ends_at = one.get("endsAt", "")
    await client.add_followup(
        ticket_id,
        f"Alerte résolue automatiquement le {ends_at}.\n"
        f"Résolution constatée par Alertmanager (fingerprint {fingerprint}).",
    )
    await client.set_status(ticket_id, STATUS_SOLVED)
    METRICS["alert2glpi_tickets_resolved_total"] += 1
    log.info("ticket #%d marked as solved for %s", ticket_id, fingerprint)
    return 1

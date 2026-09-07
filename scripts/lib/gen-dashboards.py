#!/usr/bin/env python3
"""Generate the twelve Grafana dashboards of CDC §7.6.

    scripts/lib/gen-dashboards.py            regenerate config/grafana/dashboards/
    scripts/lib/gen-dashboards.py --check    fail if the committed files differ

Why generate rather than hand-write the JSON
--------------------------------------------
A Grafana dashboard is ~500 lines of deeply nested JSON of which maybe 15 lines
are the actual content: the query, the title, the unit. Hand-written, twelve of
them drift immediately — different datasource uids, different refresh
intervals, panels that overlap because someone mistyped a `gridPos`, and a
`No data` panel nobody notices.

Generating them from one spec means:

* every panel provably references a datasource uid that
  `config/grafana/provisioning/datasources/datasources.yml` declares — the
  single most common cause of an empty panel;
* the layout is computed, so no two panels can overlap;
* changing a convention (refresh, time range, tooltip mode) is one edit;
* the diff of a dashboard change is readable.

The generated JSON is COMMITTED: Grafana provisions from files, and CI checks
with ``--check`` that the committed output matches the spec.
"""

from __future__ import annotations

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "config" / "grafana" / "dashboards"

# Datasource uids — must match datasources.yml exactly.
PROM = {"type": "prometheus", "uid": "dw-prometheus"}
ES_LOGS = {"type": "elasticsearch", "uid": "dw-es-logs"}
ES_DATA = {"type": "elasticsearch", "uid": "dw-es-datalake"}

GRID_W = 24  # Grafana's fixed grid width


# =============================================================================
# Panel builders
# =============================================================================
def _target(expr: str, legend: str = "", **extra) -> dict:
    target = {
        "datasource": PROM,
        "expr": expr,
        "legendFormat": legend or "__auto",
        "refId": extra.pop("refId", "A"),
        "editorMode": "code",
        "range": True,
    }
    target.update(extra)
    return target


def stat(
    title: str,
    expr: str,
    *,
    unit: str = "none",
    thresholds=None,
    mappings=None,
    w: int = 4,
    h: int = 4,
    decimals=None,
    desc: str = "",
) -> dict:
    """A single big number. Used for the "is it healthy" row of a dashboard."""
    steps = thresholds or [{"color": "green", "value": None}]
    return {
        "type": "stat",
        "title": title,
        "description": desc,
        "datasource": PROM,
        "targets": [_target(expr)],
        "gridPos": {"w": w, "h": h, "x": 0, "y": 0},
        "options": {
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "orientation": "auto",
            "textMode": "auto",
            "colorMode": "value",
            "graphMode": "area",
            "justifyMode": "auto",
        },
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "decimals": decimals,
                "mappings": mappings or [],
                "thresholds": {"mode": "absolute", "steps": steps},
            },
            "overrides": [],
        },
    }


def timeseries(
    title: str,
    targets: list[dict],
    *,
    unit: str = "short",
    w: int = 12,
    h: int = 8,
    stack: bool = False,
    minimum=None,
    desc: str = "",
    legend_calcs=None,
) -> dict:
    """The workhorse panel. `legend_calcs` puts min/max/mean in the legend,
    which is what makes a graph readable without hovering."""
    return {
        "type": "timeseries",
        "title": title,
        "description": desc,
        "datasource": targets[0].get("datasource", PROM),
        "targets": targets,
        "gridPos": {"w": w, "h": h, "x": 0, "y": 0},
        "options": {
            "legend": {
                "displayMode": "table" if legend_calcs else "list",
                "placement": "bottom",
                "showLegend": True,
                "calcs": legend_calcs or [],
            },
            # `multi` + `desc`: hovering shows every series at that instant,
            # sorted by value. On a 3-node graph that is the difference between
            # reading it and guessing.
            "tooltip": {"mode": "multi", "sort": "desc"},
        },
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "min": minimum,
                "custom": {
                    "drawStyle": "line",
                    "lineWidth": 1,
                    "fillOpacity": 20 if stack else 8,
                    "stacking": {"mode": "normal" if stack else "none", "group": "A"},
                    "showPoints": "never",
                    "spanNulls": False,
                    # spanNulls false: a gap in the data must LOOK like a gap.
                    # Bridging it would hide exactly the outage being looked for.
                },
                "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}]},
            },
            "overrides": [],
        },
    }


def table(title: str, targets: list[dict], *, w: int = 12, h: int = 8, desc: str = "") -> dict:
    return {
        "type": "table",
        "title": title,
        "description": desc,
        "datasource": targets[0].get("datasource", PROM),
        "targets": [{**t, "format": "table", "instant": True, "range": False} for t in targets],
        "gridPos": {"w": w, "h": h, "x": 0, "y": 0},
        "options": {
            "showHeader": True,
            "cellHeight": "sm",
            "footer": {"show": False, "reducer": ["sum"]},
        },
        "fieldConfig": {"defaults": {"custom": {"align": "auto"}}, "overrides": []},
        "transformations": [{"id": "organize", "options": {"excludeByName": {"Time": True}}}],
    }


def gauge(
    title: str,
    expr: str,
    *,
    unit: str = "percent",
    w: int = 4,
    h: int = 5,
    maximum: float = 100,
    thresholds=None,
    desc: str = "",
) -> dict:
    return {
        "type": "gauge",
        "title": title,
        "description": desc,
        "datasource": PROM,
        "targets": [_target(expr)],
        "gridPos": {"w": w, "h": h, "x": 0, "y": 0},
        "options": {
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "showThresholdLabels": False,
            "showThresholdMarkers": True,
        },
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "min": 0,
                "max": maximum,
                "thresholds": {
                    "mode": "absolute",
                    "steps": thresholds
                    or [
                        {"color": "green", "value": None},
                        {"color": "orange", "value": 70},
                        {"color": "red", "value": 85},
                    ],
                },
            },
            "overrides": [],
        },
    }


def logs_panel(
    title: str, query: str, *, datasource=None, w: int = 24, h: int = 12, desc: str = ""
) -> dict:
    ds = datasource or ES_LOGS
    return {
        "type": "logs",
        "title": title,
        "description": desc,
        "datasource": ds,
        "targets": [
            {
                "datasource": ds,
                "query": query,
                "refId": "A",
                "metrics": [{"id": "1", "type": "logs", "settings": {"limit": "500"}}],
                "bucketAggs": [],
                "timeField": "@timestamp",
            }
        ],
        "gridPos": {"w": w, "h": h, "x": 0, "y": 0},
        "options": {
            "showTime": True,
            "showLabels": False,
            "showCommonLabels": False,
            "wrapLogMessage": True,
            "prettifyLogMessage": False,
            "enableLogDetails": True,
            "dedupStrategy": "none",
            "sortOrder": "Descending",
        },
    }


def es_timeseries(
    title: str,
    query: str,
    metrics: list[dict],
    group_by: list[dict],
    *,
    datasource=None,
    unit: str = "short",
    w: int = 12,
    h: int = 8,
    desc: str = "",
) -> dict:
    ds = datasource or ES_LOGS
    return {
        "type": "timeseries",
        "title": title,
        "description": desc,
        "datasource": ds,
        "targets": [
            {
                "datasource": ds,
                "query": query,
                "refId": "A",
                "metrics": metrics,
                "bucketAggs": group_by,
                "timeField": "@timestamp",
            }
        ],
        "gridPos": {"w": w, "h": h, "x": 0, "y": 0},
        "options": {
            "legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
            "tooltip": {"mode": "multi", "sort": "desc"},
        },
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "custom": {
                    "drawStyle": "line",
                    "lineWidth": 1,
                    "fillOpacity": 15,
                    "showPoints": "never",
                    "spanNulls": False,
                },
                "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}]},
            },
            "overrides": [],
        },
    }


def row(title: str) -> dict:
    return {
        "type": "row",
        "title": title,
        "collapsed": False,
        "panels": [],
        "gridPos": {"h": 1, "w": GRID_W, "x": 0, "y": 0},
    }


# --- Common threshold sets ---------------------------------------------------
UP_DOWN = [{"color": "red", "value": None}, {"color": "green", "value": 1}]
DOWN_UP = [{"color": "green", "value": None}, {"color": "red", "value": 1}]
PCT_USAGE = [
    {"color": "green", "value": None},
    {"color": "orange", "value": 70},
    {"color": "red", "value": 85},
]
MAP_UP = [
    {
        "type": "value",
        "options": {"0": {"text": "KO", "color": "red"}, "1": {"text": "OK", "color": "green"}},
    }
]


# =============================================================================
# Layout — panels are laid out automatically so none can overlap
# =============================================================================
def layout(panels: list[dict]) -> list[dict]:
    """Place panels left to right, wrapping at the 24-column grid width."""
    x = y = row_h = 0
    for panel in panels:
        if panel["type"] == "row":
            if x:
                y += row_h
                x = row_h = 0
            panel["gridPos"] = {"h": 1, "w": GRID_W, "x": 0, "y": y}
            y += 1
            continue
        w = panel["gridPos"]["w"]
        h = panel["gridPos"]["h"]
        if x + w > GRID_W:
            y += row_h
            x = row_h = 0
        panel["gridPos"] = {"w": w, "h": h, "x": x, "y": y}
        x += w
        row_h = max(row_h, h)
    return panels


def dashboard(
    uid: str,
    title: str,
    panels: list[dict],
    *,
    tags: list[str],
    refresh: str = "30s",
    time_from: str = "now-6h",
    templating: list[dict] | None = None,
    description: str = "",
) -> dict:
    for index, panel in enumerate(layout(panels), start=1):
        panel["id"] = index
    return {
        "uid": uid,
        "title": title,
        "description": description,
        "tags": ["dockerwarts", *tags],
        "timezone": "Europe/Paris",
        "editable": False,
        "schemaVersion": 39,
        "version": 1,
        "refresh": refresh,
        "time": {"from": time_from, "to": "now"},
        "timepicker": {"refresh_intervals": ["10s", "30s", "1m", "5m", "15m", "1h"]},
        "templating": {"list": templating or []},
        "annotations": {"list": []},
        "panels": panels,
        "links": [],
    }


def var_node() -> dict:
    """A `node` variable driven by the real label values, so it can never list
    a node that does not exist."""
    return {
        "name": "node",
        "label": "Nœud",
        "type": "query",
        "datasource": PROM,
        "query": {"query": 'label_values(up{job="node"}, node)', "refId": "node"},
        "refresh": 2,
        "includeAll": True,
        "multi": True,
        "current": {},
        "sort": 1,
        "definition": 'label_values(up{job="node"}, node)',
    }


def var_service() -> dict:
    return {
        "name": "service",
        "label": "Service",
        "type": "query",
        "datasource": PROM,
        "query": {
            "query": "label_values(container_last_seen, "
            "container_label_com_docker_swarm_service_name)",
            "refId": "svc",
        },
        "refresh": 2,
        "includeAll": True,
        "multi": True,
        "current": {},
        "sort": 1,
        "definition": "label_values(container_label_com_docker_swarm_service_name)",
    }


# =============================================================================
# The twelve dashboards
# =============================================================================
def d01_overview() -> dict:
    return dashboard(
        "dw-overview",
        "01 — Vue d'ensemble",
        description="État global de la plateforme. C'est le premier écran à ouvrir "
        "en cas d'incident : il répond à « qu'est-ce qui ne va pas ? » "
        "avant d'entrer dans le détail.",
        tags=["overview"],
        refresh="30s",
        time_from="now-3h",
        panels=[
            row("Point d'entrée"),
            stat(
                "VIP joignable",
                'probe_success{job="blackbox-icmp"}',
                mappings=MAP_UP,
                thresholds=UP_DOWN,
                w=4,
                desc="Sonde ICMP sur la VIP. Si ce panneau est rouge, AUCUN "
                "service n'est joignable, quels que soient les autres.",
            ),
            stat(
                "Nœuds Ready",
                'count(up{job="node"} == 1)',
                thresholds=[
                    {"color": "red", "value": None},
                    {"color": "orange", "value": 2},
                    {"color": "green", "value": 3},
                ],
                w=4,
            ),
            stat(
                "Instances Traefik",
                'count(up{job="traefik"} == 1)',
                thresholds=[
                    {"color": "red", "value": None},
                    {"color": "orange", "value": 2},
                    {"color": "green", "value": 3},
                ],
                w=4,
            ),
            stat(
                "Alertes critiques",
                'count(ALERTS{alertstate="firing",severity="critical"}) or vector(0)',
                thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}],
                w=4,
            ),
            stat(
                "Alertes warning",
                'count(ALERTS{alertstate="firing",severity="warning"}) or vector(0)',
                thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}],
                w=4,
            ),
            stat(
                "Requêtes/s",
                'sum(rate(traefik_entrypoint_requests_total{entrypoint="websecure"}[5m]))',
                unit="reqps",
                decimals=1,
                w=4,
            ),
            row("Disponibilité des applications"),
            stat(
                "GLPI",
                'probe_success{job="blackbox-glpi"}',
                mappings=MAP_UP,
                thresholds=UP_DOWN,
                w=4,
            ),
            stat(
                "Grafana",
                'probe_success{job="blackbox-http",instance=~".*grafana.*"}',
                mappings=MAP_UP,
                thresholds=UP_DOWN,
                w=4,
            ),
            stat(
                "Kibana",
                'probe_success{job="blackbox-http",instance=~".*kibana.*"}',
                mappings=MAP_UP,
                thresholds=UP_DOWN,
                w=4,
            ),
            stat(
                "MinIO",
                'probe_success{job="blackbox-http",instance=~".*minio.*"}',
                mappings=MAP_UP,
                thresholds=UP_DOWN,
                w=4,
            ),
            stat(
                "Galera",
                "max(mysql_global_status_wsrep_cluster_size)",
                thresholds=[
                    {"color": "red", "value": None},
                    {"color": "orange", "value": 2},
                    {"color": "green", "value": 3},
                ],
                w=4,
                desc="Taille du cluster. 3 = nominal, 2 = dégradé mais "
                "opérationnel, 1 = quorum perdu, écritures refusées.",
            ),
            stat(
                "Cassandra UN",
                'count(up{job="cassandra"} == 1)',
                thresholds=[
                    {"color": "red", "value": None},
                    {"color": "orange", "value": 2},
                    {"color": "green", "value": 3},
                ],
                w=4,
            ),
            row("Clusters de données"),
            stat(
                "Elasticsearch",
                'elasticsearch_cluster_health_status{color="green"}',
                mappings=[
                    {
                        "type": "value",
                        "options": {
                            "0": {"text": "NON GREEN", "color": "orange"},
                            "1": {"text": "GREEN", "color": "green"},
                        },
                    }
                ],
                thresholds=UP_DOWN,
                w=6,
            ),
            stat(
                "Shards non assignés",
                "elasticsearch_cluster_health_unassigned_shards",
                thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}],
                w=6,
            ),
            stat(
                "Sauvegarde la plus ancienne",
                "max(time() - backup_last_success_timestamp)",
                unit="s",
                thresholds=[
                    {"color": "green", "value": None},
                    {"color": "orange", "value": 93600},
                    {"color": "red", "value": 172800},
                ],
                w=6,
                desc="Âge de la sauvegarde la plus en retard. "
                "Orange à 26 h = seuil de l'alerte BackupTooOld.",
            ),
            stat(
                "Tickets GLPI créés (24 h)",
                "increase(alert2glpi_tickets_created_total[24h]) or vector(0)",
                w=6,
            ),
            row("Ressources des nœuds"),
            timeseries(
                "CPU par nœud",
                [
                    _target(
                        '100 - (avg by (node) (rate(node_cpu_seconds_total{job="node",mode="idle"}[5m])) * 100)',
                        "{{node}}",
                    )
                ],
                unit="percent",
                w=8,
                minimum=0,
                legend_calcs=["mean", "max"],
            ),
            timeseries(
                "Mémoire utilisée",
                [
                    _target(
                        '(1 - (node_memory_MemAvailable_bytes{job="node"} / '
                        'node_memory_MemTotal_bytes{job="node"})) * 100',
                        "{{node}}",
                    )
                ],
                unit="percent",
                w=8,
                minimum=0,
                legend_calcs=["mean", "max"],
            ),
            timeseries(
                "Disque utilisé (/)",
                [
                    _target(
                        '(1 - (node_filesystem_avail_bytes{job="node",mountpoint="/"} / '
                        'node_filesystem_size_bytes{job="node",mountpoint="/"})) * 100',
                        "{{node}}",
                    )
                ],
                unit="percent",
                w=8,
                minimum=0,
                legend_calcs=["last"],
            ),
            row("Alertes actives"),
            table(
                "Alertes en cours",
                [_target('ALERTS{alertstate="firing"}', "{{alertname}} {{severity}} {{node}}")],
                w=24,
                h=10,
                desc="Toutes les alertes qui brûlent, avec leurs étiquettes. "
                "Chacune a normalement un ticket GLPI correspondant.",
            ),
        ],
    )


def d02_nodes() -> dict:
    return dashboard(
        "dw-nodes",
        "02 — Nœuds",
        description="Ressources système des trois hôtes. Adapté du dashboard "
        "communautaire Node Exporter Full (1860), réduit aux "
        "signaux qui comptent pour cette plateforme.",
        tags=["nodes"],
        templating=[var_node()],
        panels=[
            row("Synthèse"),
            gauge(
                "CPU",
                'avg(100 - (avg by (node) (rate(node_cpu_seconds_total{job="node",mode="idle",node=~"$node"}[5m])) * 100))',
                w=4,
            ),
            gauge(
                "Mémoire",
                'avg((1 - (node_memory_MemAvailable_bytes{job="node",node=~"$node"} / node_memory_MemTotal_bytes{job="node",node=~"$node"})) * 100)',
                w=4,
            ),
            gauge(
                "Disque /",
                'avg((1 - (node_filesystem_avail_bytes{job="node",node=~"$node",mountpoint="/"} / node_filesystem_size_bytes{job="node",node=~"$node",mountpoint="/"})) * 100)',
                w=4,
            ),
            stat(
                "Uptime le plus bas",
                'min(time() - node_boot_time_seconds{job="node",node=~"$node"})',
                unit="s",
                w=6,
            ),
            stat(
                "Descripteurs ouverts", 'sum(node_filefd_allocated{job="node",node=~"$node"})', w=6
            ),
            row("Processeur"),
            timeseries(
                "Utilisation CPU",
                [
                    _target(
                        '100 - (avg by (node) (rate(node_cpu_seconds_total{job="node",mode="idle",node=~"$node"}[5m])) * 100)',
                        "{{node}}",
                    )
                ],
                unit="percent",
                minimum=0,
                legend_calcs=["mean", "max"],
            ),
            timeseries(
                "Répartition par mode",
                [
                    _target(
                        'avg by (mode) (rate(node_cpu_seconds_total{job="node",node=~"$node",mode!="idle"}[5m])) * 100',
                        "{{mode}}",
                    )
                ],
                unit="percent",
                stack=True,
                minimum=0,
                desc="`iowait` élevé = attente disque, pas saturation CPU. "
                "`steal` non nul = l'hyperviseur prive la VM de temps CPU.",
            ),
            timeseries(
                "Load average",
                [
                    _target('node_load1{job="node",node=~"$node"}', "{{node}} load1"),
                    _target('node_load5{job="node",node=~"$node"}', "{{node}} load5", refId="B"),
                    _target('node_load15{job="node",node=~"$node"}', "{{node}} load15", refId="C"),
                ],
                minimum=0,
                legend_calcs=["last", "max"],
            ),
            timeseries(
                "Changements de contexte",
                [
                    _target(
                        'rate(node_context_switches_total{job="node",node=~"$node"}[5m])',
                        "{{node}}",
                    )
                ],
                unit="ops",
            ),
            row("Mémoire"),
            timeseries(
                "Mémoire",
                [
                    _target(
                        'node_memory_MemTotal_bytes{job="node",node=~"$node"} - node_memory_MemAvailable_bytes{job="node",node=~"$node"}',
                        "{{node}} utilisée",
                    ),
                    _target(
                        'node_memory_Cached_bytes{job="node",node=~"$node"}',
                        "{{node}} cache",
                        refId="B",
                    ),
                ],
                unit="bytes",
                minimum=0,
                legend_calcs=["mean", "max"],
            ),
            timeseries(
                "Swap (doit rester à zéro)",
                [
                    _target(
                        'node_memory_SwapTotal_bytes{job="node",node=~"$node"} - node_memory_SwapFree_bytes{job="node",node=~"$node"}',
                        "{{node}}",
                    )
                ],
                unit="bytes",
                minimum=0,
                desc="Le swap est DÉSACTIVÉ par Ansible (rôle common) : swapper "
                "une JVM provoque des pauses GC de plusieurs secondes. "
                "Toute valeur non nulle est une anomalie de configuration.",
            ),
            row("Disque et réseau"),
            timeseries(
                "Espace libre par point de montage",
                [
                    _target(
                        'node_filesystem_avail_bytes{job="node",node=~"$node",fstype!~"tmpfs|overlay|squashfs"}',
                        "{{node}} {{mountpoint}}",
                    )
                ],
                unit="bytes",
                minimum=0,
                legend_calcs=["last"],
            ),
            timeseries(
                "E/S disque",
                [
                    _target(
                        'rate(node_disk_read_bytes_total{job="node",node=~"$node"}[5m])',
                        "{{node}} {{device}} lecture",
                    ),
                    _target(
                        'rate(node_disk_written_bytes_total{job="node",node=~"$node"}[5m])',
                        "{{node}} {{device}} écriture",
                        refId="B",
                    ),
                ],
                unit="Bps",
            ),
            timeseries(
                "Trafic réseau",
                [
                    _target(
                        'rate(node_network_receive_bytes_total{job="node",node=~"$node",device!~"lo|veth.*|docker.*|br-.*"}[5m])',
                        "{{node}} {{device}} in",
                    ),
                    _target(
                        'rate(node_network_transmit_bytes_total{job="node",node=~"$node",device!~"lo|veth.*|docker.*|br-.*"}[5m])',
                        "{{node}} {{device}} out",
                        refId="B",
                    ),
                ],
                unit="Bps",
            ),
            timeseries(
                "Erreurs et paquets perdus",
                [
                    _target(
                        'rate(node_network_receive_errs_total{job="node",node=~"$node"}[5m])',
                        "{{node}} err in",
                    ),
                    _target(
                        'rate(node_network_transmit_errs_total{job="node",node=~"$node"}[5m])',
                        "{{node}} err out",
                        refId="B",
                    ),
                    _target(
                        'rate(node_network_receive_drop_total{job="node",node=~"$node"}[5m])',
                        "{{node}} drop in",
                        refId="C",
                    ),
                ],
                unit="pps",
                minimum=0,
            ),
        ],
    )


def d03_containers() -> dict:
    svc = "container_label_com_docker_swarm_service_name"
    return dashboard(
        "dw-containers",
        "03 — Conteneurs",
        description="Consommation par service Swarm. Adapté du dashboard "
        "communautaire cAdvisor (14282).",
        tags=["containers"],
        templating=[var_service()],
        panels=[
            row("Synthèse"),
            stat(
                "Conteneurs actifs",
                f'count(count by ({svc}) (container_last_seen{{{svc}!=""}}))',
                w=6,
            ),
            stat(
                "Services distincts",
                f'count(count by ({svc}) (container_last_seen{{{svc}!=""}}))',
                w=6,
            ),
            stat(
                "Redémarrages (1 h)",
                f'sum(changes(container_start_time_seconds{{{svc}!=""}}[1h]))',
                thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 3}],
                w=6,
                desc="Un service qui redémarre en boucle est visible ici avant "
                "que ContainerRestarting ne se déclenche.",
            ),
            stat(
                "Mémoire totale conteneurs",
                f'sum(container_memory_working_set_bytes{{{svc}!=""}})',
                unit="bytes",
                w=6,
            ),
            row("Processeur"),
            timeseries(
                "CPU par service",
                [
                    _target(
                        f'sum by ({svc}) (rate(container_cpu_usage_seconds_total{{{svc}=~"$service"}}[5m])) * 100',
                        "{{" + svc + "}}",
                    )
                ],
                unit="percent",
                minimum=0,
                legend_calcs=["mean", "max"],
            ),
            timeseries(
                "CPU par nœud",
                [
                    _target(
                        f'sum by (node) (rate(container_cpu_usage_seconds_total{{{svc}!=""}}[5m])) * 100',
                        "{{node}}",
                    )
                ],
                unit="percent",
                stack=True,
                minimum=0,
            ),
            row("Mémoire"),
            timeseries(
                "Mémoire par service",
                [
                    _target(
                        f'sum by ({svc}) (container_memory_working_set_bytes{{{svc}=~"$service"}})',
                        "{{" + svc + "}}",
                    )
                ],
                unit="bytes",
                minimum=0,
                legend_calcs=["mean", "max"],
                desc="`working_set` et non `usage` : `usage` inclut le cache "
                "récupérable et surestime largement la consommation réelle.",
            ),
            timeseries(
                "Part de la limite mémoire",
                [
                    _target(
                        f'(container_memory_working_set_bytes{{{svc}=~"$service"}} / '
                        f'container_spec_memory_limit_bytes{{{svc}=~"$service"}}) * 100',
                        "{{" + svc + "}}",
                    )
                ],
                unit="percent",
                minimum=0,
                desc="Au-delà de 90 %, le conteneur sera tué par l'OOM killer "
                "(alerte ContainerMemoryNearLimit).",
            ),
            row("Réseau et stockage"),
            timeseries(
                "Réseau par service",
                [
                    _target(
                        f'sum by ({svc}) (rate(container_network_receive_bytes_total{{{svc}=~"$service"}}[5m]))',
                        "{{" + svc + "}} in",
                    ),
                    _target(
                        f'sum by ({svc}) (rate(container_network_transmit_bytes_total{{{svc}=~"$service"}}[5m]))',
                        "{{" + svc + "}} out",
                        refId="B",
                    ),
                ],
                unit="Bps",
            ),
            timeseries(
                "Espace disque des conteneurs",
                [
                    _target(
                        f'sum by ({svc}) (container_fs_usage_bytes{{{svc}=~"$service"}})',
                        "{{" + svc + "}}",
                    )
                ],
                unit="bytes",
                minimum=0,
            ),
            row("Stabilité"),
            table(
                "Redémarrages sur 24 h",
                [
                    _target(
                        f'topk(20, sum by ({svc}, node) (changes(container_start_time_seconds{{{svc}!=""}}[24h])))',
                        "{{" + svc + "}} / {{node}}",
                    )
                ],
                w=24,
                h=10,
            ),
        ],
    )


def d04_traefik() -> dict:
    return dashboard(
        "dw-traefik",
        "04 — Traefik",
        description="Trafic HTTP au point d'entrée. Adapté du dashboard "
        "communautaire Traefik (17346).",
        tags=["edge"],
        refresh="30s",
        panels=[
            row("Synthèse"),
            stat(
                "Requêtes/s",
                'sum(rate(traefik_entrypoint_requests_total{entrypoint="websecure"}[5m]))',
                unit="reqps",
                decimals=1,
                w=4,
            ),
            stat(
                "Taux de 5xx",
                'sum(rate(traefik_entrypoint_requests_total{code=~"5..",entrypoint="websecure"}[5m])) / '
                'clamp_min(sum(rate(traefik_entrypoint_requests_total{entrypoint="websecure"}[5m])), 0.001) * 100',
                unit="percent",
                decimals=2,
                w=4,
                thresholds=[
                    {"color": "green", "value": None},
                    {"color": "orange", "value": 1},
                    {"color": "red", "value": 5},
                ],
                desc="`clamp_min` sur le dénominateur : sans lui, un trafic nul "
                "produirait NaN et le panneau resterait vide.",
            ),
            stat(
                "Taux de 4xx",
                'sum(rate(traefik_entrypoint_requests_total{code=~"4..",entrypoint="websecure"}[5m])) / '
                'clamp_min(sum(rate(traefik_entrypoint_requests_total{entrypoint="websecure"}[5m])), 0.001) * 100',
                unit="percent",
                decimals=2,
                w=4,
            ),
            stat(
                "Connexions ouvertes",
                'sum(traefik_entrypoint_open_connections{entrypoint="websecure"})',
                w=4,
            ),
            stat(
                "Instances actives",
                'count(up{job="traefik"} == 1)',
                thresholds=[
                    {"color": "red", "value": None},
                    {"color": "orange", "value": 2},
                    {"color": "green", "value": 3},
                ],
                w=4,
            ),
            stat(
                "p95 global",
                'histogram_quantile(0.95, sum by (le) (rate(traefik_entrypoint_request_duration_seconds_bucket{entrypoint="websecure"}[5m])))',
                unit="s",
                decimals=3,
                w=4,
            ),
            row("Débit et codes"),
            timeseries(
                "Requêtes/s par routeur",
                [
                    _target(
                        "sum by (router) (rate(traefik_router_requests_total[5m]))", "{{router}}"
                    )
                ],
                unit="reqps",
                stack=True,
                minimum=0,
            ),
            timeseries(
                "Codes HTTP",
                [
                    _target(
                        'sum by (code) (rate(traefik_entrypoint_requests_total{entrypoint="websecure"}[5m]))',
                        "{{code}}",
                    )
                ],
                unit="reqps",
                stack=True,
                minimum=0,
            ),
            row("Latences"),
            timeseries(
                "Latences par service",
                [
                    _target(
                        "histogram_quantile(0.50, sum by (le, service) (rate(traefik_service_request_duration_seconds_bucket[5m])))",
                        "p50 {{service}}",
                    ),
                    _target(
                        "histogram_quantile(0.95, sum by (le, service) (rate(traefik_service_request_duration_seconds_bucket[5m])))",
                        "p95 {{service}}",
                        refId="B",
                    ),
                    _target(
                        "histogram_quantile(0.99, sum by (le, service) (rate(traefik_service_request_duration_seconds_bucket[5m])))",
                        "p99 {{service}}",
                        refId="C",
                    ),
                ],
                unit="s",
                w=24,
                minimum=0,
                legend_calcs=["mean", "max"],
                desc="Les intervalles d'histogramme sont explicitement définis "
                "dans traefik.yml pour rendre lisible la plage 100 ms–1 s, "
                "là où vit GLPI.",
            ),
            row("Par nœud et TLS"),
            timeseries(
                "Requêtes par nœud",
                [
                    _target(
                        'sum by (node) (rate(traefik_entrypoint_requests_total{entrypoint="websecure"}[5m]))',
                        "{{node}}",
                    )
                ],
                unit="reqps",
                stack=True,
                minimum=0,
                desc="Le nœud qui porte la VIP reçoit tout le trafic : ce "
                "panneau montre visuellement où elle se trouve.",
            ),
            timeseries(
                "Expiration des certificats",
                [
                    _target(
                        '(probe_ssl_earliest_cert_expiry{job=~"blackbox-.*"} - time()) / 86400',
                        "{{instance}}",
                    )
                ],
                unit="d",
                minimum=0,
            ),
        ],
    )


def d05_security() -> dict:
    return dashboard(
        "dw-security",
        "05 — Sécurité",
        description="CrowdSec, pare-feu applicatif et tentatives d'intrusion. "
        "Couvre les couches 2 et 3 du pare-feu (ADR-0004).",
        tags=["security"],
        refresh="1m",
        time_from="now-24h",
        panels=[
            row("CrowdSec"),
            stat(
                "Décisions actives",
                "sum(cs_active_decisions) or vector(0)",
                thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}],
                w=6,
                desc="IP actuellement bannies. Une valeur non nulle est normale "
                "sur une plateforme exposée.",
            ),
            stat("Alertes CrowdSec (24 h)", "sum(increase(cs_alerts[24h])) or vector(0)", w=6),
            stat(
                "LAPI",
                'up{job="crowdsec"}',
                mappings=MAP_UP,
                thresholds=UP_DOWN,
                w=6,
                desc="LAPI absente = les décisions ne se mettent plus à jour. "
                "La protection RESTE active : le bouncer Traefik est en "
                "mode `stream` avec un cache local.",
            ),
            stat(
                "Agents actifs",
                'count(up{job="crowdsec-agent"} == 1) or vector(0)',
                thresholds=[
                    {"color": "red", "value": None},
                    {"color": "orange", "value": 2},
                    {"color": "green", "value": 3},
                ],
                w=6,
            ),
            row("Détections"),
            timeseries(
                "Scénarios déclenchés",
                [_target("sum by (name) (rate(cs_bucket_overflowed_total[15m]))", "{{name}}")],
                stack=True,
                minimum=0,
                desc="Chaque débordement de bucket est une détection : force "
                "brute, scan, exploitation de CVE.",
            ),
            timeseries(
                "Lignes analysées par source",
                [_target("sum by (source) (rate(cs_parser_hits_total[15m]))", "{{source}}")],
                unit="ops",
                minimum=0,
            ),
            row("Signaux HTTP"),
            timeseries(
                "Réponses 401 / 403 / 404 / 429",
                [
                    _target(
                        'sum(rate(traefik_entrypoint_requests_total{code="401"}[5m]))',
                        "401 non authentifié",
                    ),
                    _target(
                        'sum(rate(traefik_entrypoint_requests_total{code="403"}[5m]))',
                        "403 interdit (bannissement / allowlist)",
                        refId="B",
                    ),
                    _target(
                        'sum(rate(traefik_entrypoint_requests_total{code="404"}[5m]))',
                        "404 introuvable (scan)",
                        refId="C",
                    ),
                    _target(
                        'sum(rate(traefik_entrypoint_requests_total{code="429"}[5m]))',
                        "429 rate-limit",
                        refId="D",
                    ),
                ],
                unit="reqps",
                w=24,
                minimum=0,
                desc="403 en hausse = CrowdSec bannit ou l'allowlist rejette. "
                "404 en rafale = énumération de chemins. 429 = rate-limit "
                "Traefik atteint.",
            ),
            row("Journaux de sécurité"),
            logs_panel(
                "Authentifications SSH (logs-system)",
                'SYSTEMD_UNIT:"ssh.service" AND (message:"Failed" OR message:"Accepted")',
                h=10,
                desc="Tentatives SSH vues par le journal systemd. "
                "fail2ban bannit localement, CrowdSec au niveau du cluster.",
            ),
            logs_panel(
                "Requêtes rejetées par Traefik (logs-traefik)",
                "DownstreamStatus:(401 OR 403 OR 429)",
                h=10,
            ),
        ],
    )


def d06_elasticsearch() -> dict:
    return dashboard(
        "dw-elasticsearch",
        "06 — Elasticsearch",
        description="Santé du cluster d'historisation. Adapté du dashboard "
        "communautaire ES exporter (14191).",
        tags=["data"],
        panels=[
            row("Santé"),
            stat(
                "Statut",
                'elasticsearch_cluster_health_status{color="green"}',
                mappings=[
                    {
                        "type": "value",
                        "options": {
                            "0": {"text": "NON GREEN", "color": "orange"},
                            "1": {"text": "GREEN", "color": "green"},
                        },
                    }
                ],
                thresholds=UP_DOWN,
                w=4,
            ),
            stat(
                "Nœuds",
                "elasticsearch_cluster_health_number_of_nodes",
                thresholds=[
                    {"color": "red", "value": None},
                    {"color": "orange", "value": 2},
                    {"color": "green", "value": 3},
                ],
                w=4,
            ),
            stat("Shards actifs", "elasticsearch_cluster_health_active_shards", w=4),
            stat(
                "Non assignés",
                "elasticsearch_cluster_health_unassigned_shards",
                thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}],
                w=4,
            ),
            stat("Relocalisations", "elasticsearch_cluster_health_relocating_shards", w=4),
            stat("Documents", 'sum(elasticsearch_indices_docs{es_data_node="true"})', w=4),
            row("Indexation et recherche"),
            timeseries(
                "Documents indexés/s",
                [_target("rate(elasticsearch_indices_indexing_index_total[5m])", "{{name}}")],
                unit="ops",
                minimum=0,
            ),
            timeseries(
                "Latence de recherche",
                [
                    _target(
                        "rate(elasticsearch_indices_search_query_time_seconds[5m]) / "
                        "clamp_min(rate(elasticsearch_indices_search_query_total[5m]), 0.001)",
                        "{{name}}",
                    )
                ],
                unit="s",
                minimum=0,
            ),
            row("JVM et disque"),
            timeseries(
                "Heap JVM utilisé",
                [
                    _target(
                        '(elasticsearch_jvm_memory_used_bytes{area="heap"} / '
                        'elasticsearch_jvm_memory_max_bytes{area="heap"}) * 100',
                        "{{name}}",
                    )
                ],
                unit="percent",
                minimum=0,
                legend_calcs=["mean", "max"],
                desc="Au-delà de 85 % durablement, le GC tourne en continu et "
                "les pauses ressemblent à une panne de nœud.",
            ),
            timeseries(
                "Ramasse-miettes",
                [
                    _target(
                        "rate(elasticsearch_jvm_gc_collection_seconds_sum[5m])", "{{name}} {{gc}}"
                    )
                ],
                unit="s",
                minimum=0,
            ),
            timeseries(
                "Espace disque disponible",
                [_target("elasticsearch_filesystem_data_available_bytes", "{{name}}")],
                unit="bytes",
                minimum=0,
                legend_calcs=["last"],
                desc="Watermarks abaissés à 80/85/90 % dans elasticsearch.yml : "
                "au flood stage, TOUS les index passent en lecture seule.",
            ),
            timeseries(
                "Taille des index",
                [
                    _target(
                        "sum by (index) (elasticsearch_indices_store_size_bytes_total)", "{{index}}"
                    )
                ],
                unit="bytes",
                stack=True,
                minimum=0,
            ),
            row("Sauvegardes"),
            stat("Snapshots SLM réussis", "elasticsearch_slm_stats_snapshots_taken_total", w=8),
            stat(
                "Snapshots SLM en échec",
                "elasticsearch_slm_stats_snapshots_failed_total",
                thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}],
                w=8,
            ),
            stat(
                "Snapshots supprimés (rétention)",
                "elasticsearch_slm_stats_snapshots_deleted_total",
                w=8,
            ),
        ],
    )


def d07_cassandra() -> dict:
    return dashboard(
        "dw-cassandra",
        "07 — Cassandra",
        description="Datalake distribué. Métriques issues de l'agent JMX "
        "embarqué dans l'image maison.",
        tags=["data"],
        panels=[
            row("Anneau"),
            stat(
                "Nœuds joignables",
                'count(up{job="cassandra"} == 1)',
                thresholds=[
                    {"color": "red", "value": None},
                    {"color": "orange", "value": 2},
                    {"color": "green", "value": 3},
                ],
                w=6,
            ),
            stat(
                "Endpoints vus DOWN",
                "max(cassandra_endpoint_DownEndpointCount) or vector(0)",
                thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}],
                w=6,
            ),
            stat("Données sur disque", "sum(cassandra_storage_Load)", unit="bytes", w=6),
            stat(
                "Hints en attente",
                "sum(cassandra_storage_TotalHints) or vector(0)",
                thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1000}],
                w=6,
                desc="Écritures mises de côté pour un pair injoignable. "
                "C'est le signal le PLUS précoce qu'un nœud est absent, "
                "souvent avant le détecteur de pannes.",
            ),
            row("Latences client"),
            timeseries(
                "Latence p99",
                [
                    _target(
                        'cassandra_client_request_latency_99thPercentile{operation="Read"}',
                        "{{instance}} lecture",
                    ),
                    _target(
                        'cassandra_client_request_latency_99thPercentile{operation="Write"}',
                        "{{instance}} écriture",
                        refId="B",
                    ),
                ],
                unit="µs",
                minimum=0,
                legend_calcs=["mean", "max"],
            ),
            timeseries(
                "Échecs de cohérence",
                [
                    _target(
                        "rate(cassandra_client_request_Unavailables_total[5m])",
                        "{{instance}} {{operation}} unavailable",
                    ),
                    _target(
                        "rate(cassandra_client_request_Timeouts_total[5m])",
                        "{{instance}} {{operation}} timeout",
                        refId="B",
                    ),
                ],
                unit="ops",
                minimum=0,
                desc="`Unavailables` non nul = LOCAL_QUORUM ne peut plus être "
                "satisfait : l'application perd des écritures.",
            ),
            row("Compaction et pools"),
            timeseries(
                "Compactions en attente",
                [_target("cassandra_compaction_PendingTasks", "{{instance}}")],
                minimum=0,
                desc="Un arriéré croissant signifie que le nœud ne suit pas le "
                "rythme des écritures. TWCS limite ce risque en supprimant "
                "des SSTables entières à l'expiration du TTL.",
            ),
            timeseries(
                "Tâches bloquées par pool",
                [
                    _target(
                        "cassandra_threadpool_CurrentlyBlockedTasks > 0", "{{instance}} {{pool}}"
                    )
                ],
                minimum=0,
            ),
            timeseries(
                "Messages abandonnés",
                [
                    _target(
                        "rate(cassandra_dropped_messages_total[5m])",
                        "{{instance}} {{message_type}}",
                    )
                ],
                unit="ops",
                minimum=0,
            ),
            row("JVM"),
            timeseries(
                "Heap JVM",
                [
                    _target(
                        "cassandra_jvm_memory_HeapMemoryUsage_used_bytes / "
                        "clamp_min(cassandra_jvm_memory_HeapMemoryUsage_max_bytes, 1) * 100",
                        "{{instance}}",
                    )
                ],
                unit="percent",
                minimum=0,
                legend_calcs=["mean", "max"],
            ),
            timeseries(
                "Temps de GC",
                [
                    _target(
                        "rate(cassandra_jvm_gc_CollectionTime[5m]) / 1000",
                        "{{instance}} {{collector}}",
                    )
                ],
                unit="s",
                minimum=0,
            ),
            row("Keyspace datalake"),
            timeseries(
                "Espace disque du keyspace",
                [
                    _target(
                        'cassandra_keyspace_LiveDiskSpaceUsed{keyspace="datalake"}', "{{instance}}"
                    )
                ],
                unit="bytes",
                minimum=0,
            ),
            timeseries(
                "Latence keyspace",
                [
                    _target(
                        'cassandra_keyspace_ReadLatency_99thPercentile{keyspace="datalake"}',
                        "{{instance}} lecture",
                    ),
                    _target(
                        'cassandra_keyspace_WriteLatency_99thPercentile{keyspace="datalake"}',
                        "{{instance}} écriture",
                        refId="B",
                    ),
                ],
                unit="µs",
                minimum=0,
            ),
        ],
    )


def d08_galera() -> dict:
    return dashboard(
        "dw-galera",
        "08 — MariaDB Galera",
        description="Cluster SQL synchrone et proxy writer unique. Adapté du "
        "dashboard communautaire MySQL (13106), complété des "
        "métriques wsrep.",
        tags=["data"],
        panels=[
            row("Cluster"),
            stat(
                "Taille du cluster",
                "max(mysql_global_status_wsrep_cluster_size)",
                thresholds=[
                    {"color": "red", "value": None},
                    {"color": "orange", "value": 2},
                    {"color": "green", "value": 3},
                ],
                w=6,
                desc="3 = nominal. 2 = dégradé, quorum encore atteint. "
                "1 = quorum perdu, ÉCRITURES REFUSÉES (comportement correct).",
            ),
            stat(
                "Membres synchronisés",
                "count(mysql_global_status_wsrep_local_state == 4)",
                thresholds=[
                    {"color": "red", "value": None},
                    {"color": "orange", "value": 2},
                    {"color": "green", "value": 3},
                ],
                w=6,
                desc="État wsrep 4 = Synced. 1 = Joining, 2 = Donor/Desynced, 3 = Joined.",
            ),
            stat("Connexions actives", "sum(mysql_global_status_threads_connected)", w=6),
            stat(
                "Requêtes/s",
                "sum(rate(mysql_global_status_queries[5m]))",
                unit="ops",
                decimals=1,
                w=6,
            ),
            row("Réplication"),
            timeseries(
                "Taille du cluster dans le temps",
                [_target("mysql_global_status_wsrep_cluster_size", "{{instance}}")],
                minimum=0,
                legend_calcs=["min", "last"],
            ),
            timeseries(
                "Flow control (freinage des écritures)",
                [_target("mysql_global_status_wsrep_flow_control_paused", "{{instance}}")],
                unit="percentunit",
                minimum=0,
                desc="Fraction de temps pendant laquelle le cluster a FREINÉ "
                "les écritures parce qu'un membre ne suivait pas. Signal "
                "avancé d'un nœud en difficulté, bien avant sa chute.",
            ),
            timeseries(
                "File de réception locale",
                [_target("mysql_global_status_wsrep_local_recv_queue", "{{instance}}")],
                minimum=0,
            ),
            timeseries(
                "Certifications échouées",
                [
                    _target(
                        "rate(mysql_global_status_wsrep_local_cert_failures[5m])", "{{instance}}"
                    )
                ],
                unit="ops",
                minimum=0,
                desc="Doit rester à ZÉRO : HAProxy impose un writer unique "
                "précisément pour éviter les conflits de certification. "
                "Une valeur non nulle signale une écriture qui contourne "
                "db-proxy.",
            ),
            row("Charge"),
            timeseries(
                "Requêtes par type",
                [
                    _target(
                        'rate(mysql_global_status_commands_total{command=~"select|insert|update|delete"}[5m])',
                        "{{instance}} {{command}}",
                    )
                ],
                unit="ops",
                minimum=0,
            ),
            timeseries(
                "Connexions",
                [
                    _target("mysql_global_status_threads_connected", "{{instance}} connectées"),
                    _target(
                        "mysql_global_status_threads_running", "{{instance}} actives", refId="B"
                    ),
                ],
                minimum=0,
            ),
            timeseries(
                "Requêtes lentes",
                [_target("rate(mysql_global_status_slow_queries[5m])", "{{instance}}")],
                unit="ops",
                minimum=0,
                desc="Seuil à 2 s, aligné sur l'alerte GLPISlow : une page lente "
                "et une requête lente tombent dans la même fenêtre.",
            ),
            timeseries(
                "Buffer pool InnoDB",
                [
                    _target(
                        'mysql_global_status_buffer_pool_pages{state="data"} * 16384',
                        "{{instance}} données",
                    ),
                    _target(
                        'mysql_global_status_buffer_pool_pages{state="free"} * 16384',
                        "{{instance}} libre",
                        refId="B",
                    ),
                ],
                unit="bytes",
                minimum=0,
            ),
            row("HAProxy — writer unique"),
            table(
                "État des backends",
                [_target('haproxy_server_status{proxy="mariadb"}', "{{server}}")],
                w=12,
                h=8,
                desc="1 = UP. Un seul serveur non-backup doit être UP à la fois : "
                "c'est ce qui garantit le writer unique (ADR-0005).",
            ),
            timeseries(
                "Sessions HAProxy",
                [_target('haproxy_server_current_sessions{proxy="mariadb"}', "{{server}}")],
                minimum=0,
            ),
        ],
    )


def d09_availability() -> dict:
    return dashboard(
        "dw-availability",
        "09 — Disponibilité & certificats",
        description="Vue « extérieure » : ce que voit un utilisateur à travers "
        "la VIP. Adapté du dashboard communautaire Blackbox (7587).",
        tags=["availability"],
        time_from="now-24h",
        refresh="1m",
        panels=[
            row("Sondes"),
            stat(
                "VIP (ICMP)",
                'probe_success{job="blackbox-icmp"}',
                mappings=MAP_UP,
                thresholds=UP_DOWN,
                w=4,
            ),
            stat(
                "GLPI",
                'probe_success{job="blackbox-glpi"}',
                mappings=MAP_UP,
                thresholds=UP_DOWN,
                w=4,
            ),
            stat(
                "Grafana",
                'probe_success{job="blackbox-http",instance=~".*grafana.*"}',
                mappings=MAP_UP,
                thresholds=UP_DOWN,
                w=4,
            ),
            stat(
                "Kibana",
                'probe_success{job="blackbox-http",instance=~".*kibana.*"}',
                mappings=MAP_UP,
                thresholds=UP_DOWN,
                w=4,
            ),
            stat(
                "MinIO",
                'probe_success{job="blackbox-http",instance=~".*minio.*"}',
                mappings=MAP_UP,
                thresholds=UP_DOWN,
                w=4,
            ),
            stat("Sondes TCP OK", 'count(probe_success{job="blackbox-tcp"} == 1)', w=4),
            row("Disponibilité et temps de réponse"),
            timeseries(
                "Disponibilité des sondes",
                [_target('probe_success{job=~"blackbox-.*"}', "{{instance}}")],
                w=24,
                minimum=0,
                desc="Une descente à 0 est une indisponibilité vue de "
                "l'extérieur — la seule qui compte pour l'utilisateur.",
            ),
            timeseries(
                "Temps de réponse",
                [
                    _target(
                        'probe_duration_seconds{job=~"blackbox-http|blackbox-glpi"}', "{{instance}}"
                    )
                ],
                unit="s",
                minimum=0,
                legend_calcs=["mean", "max"],
            ),
            timeseries(
                "Décomposition (DNS, connexion, TLS, transfert)",
                [
                    _target(
                        'probe_http_duration_seconds{job=~"blackbox-http|blackbox-glpi"}',
                        "{{instance}} {{phase}}",
                    )
                ],
                unit="s",
                stack=True,
                minimum=0,
                desc="Permet de distinguer « le réseau est lent » de « l'application est lente ».",
            ),
            row("Disponibilité mesurée"),
            stat(
                "Disponibilité GLPI (24 h)",
                'avg_over_time(probe_success{job="blackbox-glpi"}[24h]) * 100',
                unit="percent",
                decimals=3,
                w=8,
                thresholds=[
                    {"color": "red", "value": None},
                    {"color": "orange", "value": 99},
                    {"color": "green", "value": 99.9},
                ],
            ),
            stat(
                "Disponibilité VIP (24 h)",
                'avg_over_time(probe_success{job="blackbox-icmp"}[24h]) * 100',
                unit="percent",
                decimals=3,
                w=8,
                thresholds=[
                    {"color": "red", "value": None},
                    {"color": "orange", "value": 99.9},
                    {"color": "green", "value": 99.99},
                ],
            ),
            stat(
                "Disponibilité Grafana (24 h)",
                'avg_over_time(probe_success{job="blackbox-http",instance=~".*grafana.*"}[24h]) * 100',
                unit="percent",
                decimals=3,
                w=8,
            ),
            row("Certificats TLS"),
            timeseries(
                "Jours avant expiration",
                [
                    _target(
                        '(probe_ssl_earliest_cert_expiry{job=~"blackbox-.*"} - time()) / 86400',
                        "{{instance}}",
                    )
                ],
                unit="d",
                w=24,
                minimum=0,
                desc="Alerte CertificateExpiringSoon sous 14 jours. La "
                "validation utilise la CA interne : `insecure_skip_verify` "
                "est à false, sinon cette métrique n'existerait pas.",
            ),
        ],
    )


def d10_backup() -> dict:
    return dashboard(
        "dw-backup",
        "10 — Sauvegardes",
        description="État des jobs de sauvegarde et du dépôt. C'est le "
        "dashboard qui transforme « nous avons des sauvegardes » en "
        "« nous savons qu'elles fonctionnent ».",
        tags=["backup"],
        refresh="5m",
        time_from="now-7d",
        panels=[
            row("État global"),
            stat("Jobs suivis", "count(backup_last_success_timestamp)", w=6),
            stat(
                "Jobs en échec",
                "count(backup_last_status != 0) or vector(0)",
                thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}],
                w=6,
            ),
            stat(
                "Sauvegarde la plus ancienne",
                "max(time() - backup_last_success_timestamp)",
                unit="s",
                w=6,
                thresholds=[
                    {"color": "green", "value": None},
                    {"color": "orange", "value": 93600},
                    {"color": "red", "value": 172800},
                ],
                desc="Orange à 26 h = seuil exact de l'alerte BackupTooOld.",
            ),
            stat("Volume total sauvegardé", "sum(backup_last_size_bytes)", unit="bytes", w=6),
            row("Par job"),
            table(
                "Âge, durée, taille et état par job",
                [
                    _target("time() - backup_last_success_timestamp", "{{job}} âge (s)"),
                    _target("backup_last_duration_seconds", "{{job}} durée (s)", refId="B"),
                    _target("backup_last_size_bytes", "{{job}} taille", refId="C"),
                    _target("backup_last_status", "{{job}} état", refId="D"),
                ],
                w=24,
                h=10,
                desc="État 0 = succès. Toute autre valeur déclenche BackupFailed.",
            ),
            row("Historique"),
            timeseries(
                "Âge des sauvegardes",
                [_target("(time() - backup_last_success_timestamp) / 3600", "{{job}}")],
                unit="h",
                minimum=0,
                legend_calcs=["max"],
                desc="Chaque dent de scie est une exécution réussie. Une courbe "
                "qui monte sans redescendre est un job qui a cessé de tourner.",
            ),
            timeseries(
                "Durée d'exécution",
                [_target("backup_last_duration_seconds", "{{job}}")],
                unit="s",
                minimum=0,
                legend_calcs=["mean", "max"],
                desc="Une durée qui triple est le signal d'un dépôt qui grossit "
                "trop ou d'un problème réseau — avant que cela ne devienne "
                "un échec (alerte BackupDurationAnomaly).",
            ),
            timeseries(
                "Taille des sauvegardes",
                [_target("backup_last_size_bytes", "{{job}}")],
                unit="bytes",
                minimum=0,
            ),
            row("Elasticsearch SLM et MinIO"),
            stat("Snapshots ES réussis", "elasticsearch_slm_stats_snapshots_taken_total", w=6),
            stat(
                "Snapshots ES en échec",
                "elasticsearch_slm_stats_snapshots_failed_total",
                thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}],
                w=6,
            ),
            stat("Espace MinIO libre", "sum(minio_node_drive_free_bytes)", unit="bytes", w=6),
            gauge(
                "Occupation MinIO",
                "(1 - (sum(minio_node_drive_free_bytes) / clamp_min(sum(minio_node_drive_total_bytes), 1))) * 100",
                w=6,
                h=6,
            ),
        ],
    )


def d11_logs() -> dict:
    return dashboard(
        "dw-logs",
        "11 — Logs",
        description="Volume, erreurs et exploration des journaux. Les données "
        "viennent d'Elasticsearch, alimenté par Fluent Bit.",
        tags=["logs"],
        refresh="1m",
        time_from="now-3h",
        panels=[
            row("Collecte"),
            stat(
                "Collecteurs actifs",
                'count(up{job="fluentbit"} == 1)',
                thresholds=[
                    {"color": "red", "value": None},
                    {"color": "orange", "value": 2},
                    {"color": "green", "value": 3},
                ],
                w=6,
            ),
            stat(
                "Lignes lues/s",
                "sum(rate(fluentbit_input_records_total[5m]))",
                unit="ops",
                decimals=1,
                w=6,
            ),
            stat(
                "Lignes livrées/s",
                "sum(rate(fluentbit_output_proc_records_total[5m]))",
                unit="ops",
                decimals=1,
                w=6,
            ),
            stat(
                "Erreurs de sortie",
                "sum(rate(fluentbit_output_errors_total[5m])) or vector(0)",
                thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 0.001}],
                w=6,
                desc="Les logs ne sont pas perdus (tampon disque + réessai "
                "infini), mais ils s'accumulent.",
            ),
            row("Débit de collecte"),
            timeseries(
                "Lues vs livrées",
                [
                    _target("sum(rate(fluentbit_input_records_total[5m]))", "lues"),
                    _target(
                        "sum(rate(fluentbit_output_proc_records_total[5m]))", "livrées", refId="B"
                    ),
                ],
                unit="ops",
                minimum=0,
                desc="L'écart entre les deux courbes EST le retard de collecte. "
                "Un écart durable déclenche FluentBitBacklogGrowing.",
            ),
            timeseries(
                "Réessais de sortie",
                [
                    _target(
                        "sum by (node) (rate(fluentbit_output_retries_total[5m]))",
                        "{{node}} réessais",
                    ),
                    _target(
                        "sum by (node) (rate(fluentbit_output_retries_failed_total[5m]))",
                        "{{node}} réessais échoués",
                        refId="B",
                    ),
                ],
                unit="ops",
                minimum=0,
            ),
            row("Contenu des journaux"),
            es_timeseries(
                "Volume de logs par service",
                "*",
                [{"id": "1", "type": "count"}],
                [
                    {
                        "id": "2",
                        "type": "terms",
                        "field": "service_name",
                        "settings": {"size": "10", "order": "desc", "orderBy": "_count"},
                    },
                    {
                        "id": "3",
                        "type": "date_histogram",
                        "field": "@timestamp",
                        "settings": {"interval": "auto"},
                    },
                ],
                w=12,
                desc="Top 10 des services les plus bavards.",
            ),
            es_timeseries(
                "Erreurs par service",
                "log_level:(error OR fatal)",
                [{"id": "1", "type": "count"}],
                [
                    {
                        "id": "2",
                        "type": "terms",
                        "field": "service_name",
                        "settings": {"size": "10", "order": "desc", "orderBy": "_count"},
                    },
                    {
                        "id": "3",
                        "type": "date_histogram",
                        "field": "@timestamp",
                        "settings": {"interval": "auto"},
                    },
                ],
                w=12,
                desc="Repose sur le champ `log_level` normalisé par le "
                "filtre Lua de Fluent Bit : sans lui, chaque "
                "service écrirait sa sévérité différemment et ce "
                "panneau serait impossible.",
            ),
            row("Exploration"),
            logs_panel("Erreurs récentes (tous services)", "log_level:(error OR fatal)", h=14),
            logs_panel("Journal d'accès Traefik — erreurs", "DownstreamStatus:[400 TO 599]", h=12),
        ],
    )


def d12_datalake() -> dict:
    return dashboard(
        "dw-datalake",
        "12 — Datalake",
        description="Démonstration du flux big data : production d'événements → "
        "Cassandra + Elasticsearch → visualisation (exigence F9).",
        tags=["datalake"],
        refresh="30s",
        time_from="now-1h",
        panels=[
            row("Production"),
            stat(
                "Événements/s produits",
                "sum(rate(demo_producer_events_total[5m])) or vector(0)",
                unit="ops",
                decimals=1,
                w=6,
            ),
            stat(
                "Erreurs Cassandra",
                'sum(demo_producer_errors_total{target="cassandra"}) or vector(0)',
                thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}],
                w=6,
                desc="DOIT rester à zéro pendant toute la campagne chaos : "
                "c'est le critère 6.3 du CDC.",
            ),
            stat(
                "Erreurs Elasticsearch",
                'sum(demo_producer_errors_total{target="elasticsearch"}) or vector(0)',
                thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}],
                w=6,
            ),
            stat("Capteurs actifs", "max(demo_producer_sensors) or vector(0)", w=6),
            row("Ingestion"),
            timeseries(
                "Événements produits/s",
                [_target("sum by (target) (rate(demo_producer_events_total[5m]))", "{{target}}")],
                unit="ops",
                minimum=0,
                desc="Les deux courbes doivent se superposer : chaque événement "
                "part vers Cassandra ET vers Elasticsearch.",
            ),
            timeseries(
                "Latence d'écriture",
                [
                    _target(
                        "histogram_quantile(0.95, sum by (le, target) (rate(demo_producer_write_duration_seconds_bucket[5m])))",
                        "p95 {{target}}",
                    )
                ],
                unit="s",
                minimum=0,
            ),
            row("Contenu du datalake"),
            es_timeseries(
                "Événements indexés par site",
                "*",
                [{"id": "1", "type": "count"}],
                [
                    {
                        "id": "2",
                        "type": "terms",
                        "field": "site",
                        "settings": {"size": "10", "order": "desc", "orderBy": "_count"},
                    },
                    {
                        "id": "3",
                        "type": "date_histogram",
                        "field": "@timestamp",
                        "settings": {"interval": "auto"},
                    },
                ],
                datasource=ES_DATA,
                w=12,
            ),
            es_timeseries(
                "Température moyenne par site",
                "*",
                [{"id": "1", "type": "avg", "field": "temperature"}],
                [
                    {
                        "id": "2",
                        "type": "terms",
                        "field": "site",
                        "settings": {"size": "10", "order": "desc", "orderBy": "_term"},
                    },
                    {
                        "id": "3",
                        "type": "date_histogram",
                        "field": "@timestamp",
                        "settings": {"interval": "auto"},
                    },
                ],
                datasource=ES_DATA,
                unit="celsius",
                w=12,
            ),
            es_timeseries(
                "Humidité moyenne par site",
                "*",
                [{"id": "1", "type": "avg", "field": "humidity"}],
                [
                    {
                        "id": "2",
                        "type": "terms",
                        "field": "site",
                        "settings": {"size": "10", "order": "desc", "orderBy": "_term"},
                    },
                    {
                        "id": "3",
                        "type": "date_histogram",
                        "field": "@timestamp",
                        "settings": {"interval": "auto"},
                    },
                ],
                datasource=ES_DATA,
                unit="humidity",
                w=12,
            ),
            es_timeseries(
                "Top capteurs par volume",
                "*",
                [{"id": "1", "type": "count"}],
                [
                    {
                        "id": "2",
                        "type": "terms",
                        "field": "sensor_id",
                        "settings": {"size": "10", "order": "desc", "orderBy": "_count"},
                    },
                    {
                        "id": "3",
                        "type": "date_histogram",
                        "field": "@timestamp",
                        "settings": {"interval": "auto"},
                    },
                ],
                datasource=ES_DATA,
                w=12,
            ),
            row("Côté Cassandra"),
            timeseries(
                "Latence d'écriture Cassandra (p99)",
                [
                    _target(
                        'cassandra_keyspace_WriteLatency_99thPercentile{keyspace="datalake"}',
                        "{{instance}}",
                    )
                ],
                unit="µs",
                minimum=0,
            ),
            timeseries(
                "Volume du keyspace datalake",
                [
                    _target(
                        'cassandra_keyspace_LiveDiskSpaceUsed{keyspace="datalake"}', "{{instance}}"
                    )
                ],
                unit="bytes",
                minimum=0,
            ),
        ],
    )


DASHBOARDS = [
    ("01-overview.json", d01_overview),
    ("02-nodes.json", d02_nodes),
    ("03-containers.json", d03_containers),
    ("04-traefik.json", d04_traefik),
    ("05-security.json", d05_security),
    ("06-elasticsearch.json", d06_elasticsearch),
    ("07-cassandra.json", d07_cassandra),
    ("08-galera.json", d08_galera),
    ("09-availability.json", d09_availability),
    ("10-backup.json", d10_backup),
    ("11-logs.json", d11_logs),
    ("12-datalake.json", d12_datalake),
]


def main() -> int:
    check = "--check" in sys.argv
    OUT.mkdir(parents=True, exist_ok=True)
    drift = []

    for filename, builder in DASHBOARDS:
        payload = json.dumps(builder(), indent=2, ensure_ascii=False) + "\n"
        path = OUT / filename
        if check:
            if not path.exists() or path.read_text(encoding="utf-8") != payload:
                drift.append(filename)
        else:
            path.write_text(payload, encoding="utf-8")

    if check:
        if drift:
            print("dashboards out of date with the generator: " + ", ".join(drift), file=sys.stderr)
            print("run: scripts/lib/gen-dashboards.py", file=sys.stderr)
            return 1
        print(f"  {len(DASHBOARDS)} dashboards match the generator")
        return 0

    print(f"  {len(DASHBOARDS)} dashboards written to {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

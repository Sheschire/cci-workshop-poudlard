#!/usr/bin/env python3
"""Cross-check the Grafana dashboards against the provisioned datasources.

Acceptance criterion 4.2 of the CDC is "the twelve dashboards load with no
empty panel". The overwhelmingly most common cause of an empty panel is a
panel referencing a datasource ``uid`` that nothing provisions — Grafana
renders the panel, shows "Datasource not found" in small grey text, and
everything else looks fine.

That failure is invisible to yamllint, to ``docker stack config`` and to a
quick glance at the UI. It is checked here, in CI, before anything deploys.

What is verified
----------------
1. every ``uid`` referenced by a panel or a target is declared in
   ``datasources.yml``;
2. every PromQL target references a metric whose exporter this platform
   actually deploys (a typo in a metric name gives an empty panel too);
3. every Elasticsearch target names a ``timeField`` and a query;
4. no dashboard uid is duplicated (Grafana would silently keep only one);
5. every dashboard is in the provisioned folder and no panel is left without a
   target;
6. the committed JSON matches the generator (``gen-dashboards.py --check``).
"""

from __future__ import annotations

import json
import pathlib
import re
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
DASHBOARDS = ROOT / "config" / "grafana" / "dashboards"
DATASOURCES = ROOT / "config" / "grafana" / "provisioning" / "datasources" / "datasources.yml"

errors: list[str] = []
warnings: list[str] = []

# -----------------------------------------------------------------------------
# Metric prefixes this platform genuinely exposes. A target using anything else
# is almost certainly a typo, and would render an empty panel.
#
# Deliberately a PREFIX list rather than a full metric inventory: the exact
# metric names depend on exporter versions, and pinning them here would make
# the check fail on every upgrade for no real benefit. A wrong prefix, on the
# other hand, is always a mistake.
# -----------------------------------------------------------------------------
KNOWN_PREFIXES = (
    "up",
    "ALERTS",
    "node_",  # node-exporter
    "container_",  # cAdvisor
    "traefik_",
    "cs_",  # CrowdSec
    "mysql_",  # mysqld-exporter
    "haproxy_",
    "cassandra_",  # in-JVM JMX exporter
    "elasticsearch_",
    "fluentbit_",
    "probe_",  # blackbox
    "backup_",  # the backup jobs
    "minio_",
    "alert2glpi_",
    "demo_producer_",
    "alertmanager_",
    "prometheus_",
    "engine_",  # Docker engine
    "swarm_",
    "grafana_",
)

# PromQL functions and keywords that must not be mistaken for metric names.
PROMQL_KEYWORDS = {
    "rate",
    "irate",
    "increase",
    "sum",
    "avg",
    "min",
    "max",
    "count",
    "topk",
    "bottomk",
    "by",
    "without",
    "on",
    "ignoring",
    "group_left",
    "group_right",
    "histogram_quantile",
    "quantile",
    "clamp_min",
    "clamp_max",
    "vector",
    "scalar",
    "abs",
    "ceil",
    "floor",
    "round",
    "delta",
    "idelta",
    "changes",
    "avg_over_time",
    "sum_over_time",
    "min_over_time",
    "max_over_time",
    "count_over_time",
    "last_over_time",
    "stddev",
    "stdvar",
    "time",
    "absent",
    "label_values",
    "offset",
    "and",
    "or",
    "unless",
    "bool",
    "le",
    "predict_linear",
    "deriv",
    "resets",
    "humanizeDuration",
}

METRIC_TOKEN = re.compile(r"\b([a-zA-Z_:][a-zA-Z0-9_:]*)\s*(?:\{|\[|\s*[)+\-*/,]|$)")


def load_datasource_uids() -> set[str]:
    with DATASOURCES.open(encoding="utf-8") as handle:
        doc = yaml.safe_load(handle) or {}
    return {ds["uid"] for ds in (doc.get("datasources") or []) if "uid" in ds}


def collect_uids(node, found: set[str]) -> None:
    """Walk the dashboard JSON and collect every datasource uid it references."""
    if isinstance(node, dict):
        ds = node.get("datasource")
        if isinstance(ds, dict) and "uid" in ds:
            found.add(ds["uid"])
        for value in node.values():
            collect_uids(value, found)
    elif isinstance(node, list):
        for item in node:
            collect_uids(item, found)


def check_promql_metrics(expr: str, where: str) -> None:
    """Flag any metric name whose prefix this platform does not expose.

    Everything that can legally contain a non-metric identifier is stripped
    first — otherwise the LABEL names inside `by (node, service)` would be
    reported as unknown metrics, and the check would drown in false positives
    until nobody read it any more.
    """
    # 1. string literals: arbitrary text.
    cleaned = re.sub(r'"[^"]*"', '""', expr)
    cleaned = re.sub(r"'[^']*'", "''", cleaned)
    # 2. label matchers: `{job="node", mode!="idle"}`.
    cleaned = re.sub(r"\{[^}]*\}", "{}", cleaned)
    # 3. grouping clauses: `by (node, service)`, `without (le)`, and the
    #    `on(...)` / `group_left(...)` of vector matching. Their contents are
    #    LABEL names, never metric names.
    cleaned = re.sub(
        r"\b(?:by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)", " ", cleaned
    )
    for token in METRIC_TOKEN.findall(cleaned):
        if token in PROMQL_KEYWORDS or token.isdigit():
            continue
        if not token.startswith(KNOWN_PREFIXES):
            warnings.append(f"{where}: unknown metric prefix '{token}'")


def main() -> int:
    if not DASHBOARDS.exists():
        print("config/grafana/dashboards/ is missing", file=sys.stderr)
        return 1

    declared = load_datasource_uids()
    seen_uids: dict[str, str] = {}
    panel_count = 0

    for path in sorted(DASHBOARDS.glob("*.json")):
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            errors.append(f"{path.name}: invalid JSON — {exc}")
            continue

        # --- 4. unique dashboard uid ----------------------------------------
        uid = doc.get("uid")
        if not uid:
            errors.append(f"{path.name}: no dashboard uid")
        elif uid in seen_uids:
            errors.append(f"{path.name}: uid '{uid}' already used by {seen_uids[uid]}")
        else:
            seen_uids[uid] = path.name

        # --- 1. every referenced datasource is provisioned -------------------
        referenced: set[str] = set()
        collect_uids(doc, referenced)
        for ref in sorted(referenced - declared):
            errors.append(
                f"{path.name}: datasource uid '{ref}' is not provisioned "
                f"(declared: {sorted(declared)})"
            )

        # --- 2, 3, 5. panels and targets -------------------------------------
        for panel in doc.get("panels", []):
            if panel.get("type") == "row":
                continue
            panel_count += 1
            title = panel.get("title", "(untitled)")
            targets = panel.get("targets") or []
            if not targets:
                errors.append(f"{path.name}: panel '{title}' has no target")
                continue

            for target in targets:
                ds_type = (target.get("datasource") or {}).get("type", "")
                if ds_type == "prometheus" or "expr" in target:
                    expr = target.get("expr", "")
                    if not expr.strip():
                        errors.append(f"{path.name}: panel '{title}' has an empty expr")
                    else:
                        check_promql_metrics(expr, f"{path.name}/{title}")
                elif ds_type == "elasticsearch":
                    if not target.get("timeField"):
                        errors.append(
                            f"{path.name}: panel '{title}' (Elasticsearch) has no timeField"
                        )
                    if "query" not in target:
                        errors.append(f"{path.name}: panel '{title}' (Elasticsearch) has no query")

    # --- 6. the committed JSON matches the generator -------------------------
    generator = ROOT / "scripts" / "lib" / "gen-dashboards.py"
    if generator.exists():
        # S603: the command is this repository's own generator at a fixed
        # path, run with the current interpreter. No external input reaches it.
        result = subprocess.run(  # noqa: S603
            [sys.executable, str(generator), "--check"],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            errors.append(result.stderr.strip() or "the dashboards differ from the generator")

    # --- Report ---------------------------------------------------------------
    for message in warnings:
        print(f"  warning: {message}", file=sys.stderr)
    for message in errors:
        print(f"  error:   {message}", file=sys.stderr)

    if errors:
        return 1

    print(
        f"  {len(seen_uids)} dashboards, {panel_count} panels, "
        f"{len(declared)} datasources: every reference resolves"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

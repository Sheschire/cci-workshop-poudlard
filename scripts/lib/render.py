#!/usr/bin/env python3
"""Substitute a fixed set of ``${VAR}`` placeholders in a configuration file.

Used by ``scripts/lib/render.sh`` (and therefore by ``scripts/deploy.sh`` and
``scripts/validate-stacks.sh``).

Why not ``envsubst``
--------------------
``envsubst`` lives in ``gettext-base``, which is not installed everywhere, and
without an explicit variable list it also expands ``$1``, ``${HOME}`` and any
shell-shaped text inside a Prometheus relabel rule or a Grafana template — a
classic way to silently corrupt a configuration. Python 3 is guaranteed on the
nodes (Ansible requires it) and lets us be strict:

* only the names in ``ALLOWED`` are substituted;
* ``$$`` is an escape for a literal ``$``;
* a placeholder naming an allowed-but-unset variable is an error, not an empty
  string — an empty ``ADMIN_CIDR`` in a Traefik allowlist would silently open
  an administration UI to the world;
* a ``${...}`` that is *not* in ``ALLOWED`` is left untouched, because that is
  how Prometheus, Grafana and Alertmanager write their own templates.

    render.py <source> <destination>
"""

from __future__ import annotations

import os
import re
import sys

# Every variable a configuration file may reference. Mirrors the list in
# render.sh and, ultimately, .env.example.
ALLOWED = (
    "DOMAIN",
    "VIP",
    "ADMIN_CIDR",
    "CLUSTER_CIDR",
    "NFS_SERVER",
    "REGISTRY",
    "IMAGE_TAG",
    "TZ",
    "PROFILE",
    "ES_HEAP",
    "CASSANDRA_HEAP",
    "CASSANDRA_NEWSIZE",
    "OFFSITE_S3_ENDPOINT",
    "OFFSITE_S3_BUCKET",
    "SMTP_HOST",
    "SMTP_PORT",
    "SMTP_FROM",
    "ALERT_EMAIL_TO",
)

# Variables that are legitimately empty when a feature is switched off.
MAY_BE_EMPTY = frozenset(
    {
        "OFFSITE_S3_ENDPOINT",
        "OFFSITE_S3_BUCKET",
        "SMTP_HOST",
        "SMTP_FROM",
        "ALERT_EMAIL_TO",
    }
)

PLACEHOLDER = re.compile(r"\$(\$)|\$\{([A-Z_][A-Z0-9_]*)\}")


def render(text: str, source: str) -> str:
    missing: list[str] = []

    def replace(match: re.Match[str]) -> str:
        if match.group(1):  # `$$` → literal `$`
            return "$"
        name = match.group(2)
        if name not in ALLOWED:
            # Not ours: a Prometheus/Grafana/Alertmanager template. Leave it be.
            return match.group(0)
        value = os.environ.get(name)
        if value is None or (value == "" and name not in MAY_BE_EMPTY):
            missing.append(name)
            return match.group(0)
        return value

    result = PLACEHOLDER.sub(replace, text)
    if missing:
        names = ", ".join(sorted(set(missing)))
        raise SystemExit(
            f"render.py: {source}: variable(s) unset or empty: {names}\n"
            f"           check your .env against .env.example"
        )
    return result


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: render.py <source> <destination>")
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, encoding="utf-8") as handle:
        text = handle.read()
    with open(dst, "w", encoding="utf-8") as handle:
        handle.write(render(text, src))
    return 0


if __name__ == "__main__":
    sys.exit(main())

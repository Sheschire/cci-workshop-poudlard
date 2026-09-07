#!/usr/bin/env python3
"""Cross-check the Traefik configuration against the stack labels.

Traefik fails *silently* on a dangling reference: a router whose
``middlewares`` label names a middleware that does not exist is dropped from
the routing table with a line in the log and nothing else. The URL then 404s,
or — much worse — a router that was supposed to carry ``admin-allowlist``
simply loses it and the administration UI becomes reachable from anywhere.

That failure mode is invisible to ``docker stack config`` and to yamllint, so
it is checked here, in CI, before anything is deployed.

What is verified
----------------
1. every ``…@file`` middleware referenced by a stack label exists in
   ``config/traefik/dynamic.yml``;
2. every ``…@file`` TLS option referenced by a stack label exists;
3. every middleware of a ``chain`` exists;
4. every router in ``dynamic.yml`` points at a declared service;
5. each administration host name of CDC §5.5 carries ``admin-allowlist``
   (directly or through a chain) — the security regression that matters most;
6. the entrypoint-wide middlewares of ``traefik.yml`` exist too.

    check-traefik.py            (run from the repository root)
"""

from __future__ import annotations

import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
STATIC = ROOT / "config" / "traefik" / "traefik.yml"
DYNAMIC = ROOT / "config" / "traefik" / "dynamic.yml"
STACKS = ROOT / "stacks"

# CDC §5.5: these host names must never be reachable outside ADMIN_CIDR.
ADMIN_HOSTS = {
    "traefik",
    "prometheus",
    "alertmanager",
    "kibana",
    "minio",
    "whoami",
}

errors: list[str] = []
warnings: list[str] = []


def load(path: pathlib.Path) -> dict:
    """Load a Traefik YAML file, leaving ``${VAR}`` placeholders as strings."""
    with path.open(encoding="utf-8") as handle:
        return yaml.safe_load(handle) or {}


def resolve_chain(name: str, middlewares: dict, seen: frozenset[str] = frozenset()) -> set[str]:
    """Flatten a middleware reference into the set of leaf middlewares it applies."""
    if name in seen:  # a chain referencing itself would loop forever
        errors.append(f"middleware chain loop involving '{name}'")
        return set()
    spec = middlewares.get(name)
    if spec is None:
        return set()
    if "chain" in spec:
        result: set[str] = set()
        for member in spec["chain"].get("middlewares", []):
            member = member.split("@")[0]
            result |= {member} | resolve_chain(member, middlewares, seen | {name})
        return result
    return {name}


def main() -> int:
    if not DYNAMIC.exists():
        print("config/traefik/dynamic.yml is missing", file=sys.stderr)
        return 1

    dynamic = load(DYNAMIC)
    static = load(STATIC) if STATIC.exists() else {}

    middlewares = (dynamic.get("http") or {}).get("middlewares") or {}
    routers = (dynamic.get("http") or {}).get("routers") or {}
    services = (dynamic.get("http") or {}).get("services") or {}
    tls_options = (dynamic.get("tls") or {}).get("options") or {}

    # --- 3. chains resolve ---------------------------------------------------
    for name, spec in middlewares.items():
        if "chain" not in spec:
            continue
        for member in spec["chain"].get("middlewares", []):
            member = member.split("@")[0]
            if member not in middlewares:
                errors.append(f"chain '{name}' references the unknown middleware '{member}'")

    # --- 6. entrypoint-wide middlewares -------------------------------------
    for ep_name, ep in (static.get("entryPoints") or {}).items():
        http = ep.get("http") or {}
        for ref in http.get("middlewares", []):
            if ref.endswith("@file") and ref.split("@")[0] not in middlewares:
                errors.append(f"entrypoint '{ep_name}' references the unknown middleware '{ref}'")
        opt = (http.get("tls") or {}).get("options")
        if opt and opt.split("@")[0] not in tls_options:
            errors.append(f"entrypoint '{ep_name}' references the unknown TLS option '{opt}'")

    # --- 4. routers of dynamic.yml point somewhere --------------------------
    for name, router in routers.items():
        service = router.get("service", "")
        if service.endswith("@internal"):
            pass  # api@internal, ping@internal: provided by Traefik
        elif service.split("@")[0] not in services:
            errors.append(f"router '{name}' references the unknown service '{service}'")
        for ref in router.get("middlewares", []):
            if ref.split("@")[0] not in middlewares:
                errors.append(f"router '{name}' references the unknown middleware '{ref}'")
        opt = (router.get("tls") or {}).get("options")
        if opt and opt.split("@")[0] not in tls_options:
            errors.append(f"router '{name}' references the unknown TLS option '{opt}'")

    # --- 1, 2, 5. the stack labels ------------------------------------------
    host_rule = re.compile(r"Host\(`([a-z0-9-]+)\.")
    for stack in sorted(STACKS.glob("*.yml")):
        doc = load(stack)
        for svc, spec in (doc.get("services") or {}).items():
            labels = ((spec.get("deploy") or {}).get("labels")) or {}
            if isinstance(labels, list):  # list form: ["k=v", …]
                labels = dict(item.split("=", 1) for item in labels if "=" in item)
            if labels.get("traefik.enable") != "true":
                continue

            for key, value in labels.items():
                # traefik.http.routers.<r>.middlewares = "a@file,b@file"
                if key.endswith(".middlewares"):
                    for ref in str(value).split(","):
                        ref = ref.strip().split("@")[0]
                        if ref and ref not in middlewares:
                            errors.append(f"{stack.name}:{svc}: unknown middleware '{ref}' ({key})")
                if key.endswith(".tls.options"):
                    ref = str(value).split("@")[0]
                    if ref not in tls_options:
                        errors.append(f"{stack.name}:{svc}: unknown TLS option '{ref}'")

                # An administration host must end up with admin-allowlist.
                if key.endswith(".rule"):
                    match = host_rule.search(str(value))
                    if not match or match.group(1) not in ADMIN_HOSTS:
                        continue
                    router = key.split(".")[3]
                    applied: set[str] = set()
                    mw_key = f"traefik.http.routers.{router}.middlewares"
                    for ref in str(labels.get(mw_key, "")).split(","):
                        ref = ref.strip().split("@")[0]
                        if ref:
                            applied |= {ref} | resolve_chain(ref, middlewares)
                    if "admin-allowlist" not in applied:
                        errors.append(
                            f"{stack.name}:{svc}: the administration route "
                            f"'{match.group(1)}' does NOT apply admin-allowlist "
                            f"(applied: {sorted(applied) or 'none'})"
                        )

    # --- Report --------------------------------------------------------------
    for message in warnings:
        print(f"  warning: {message}", file=sys.stderr)
    for message in errors:
        print(f"  error:   {message}", file=sys.stderr)
    if errors:
        return 1
    print(
        f"  {len(middlewares)} middlewares, {len(routers)} static routers, "
        f"{len(tls_options)} TLS option set(s): every reference resolves"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

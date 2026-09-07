#!/usr/bin/env python3
"""Turn a merged stack into one a single-node Swarm can actually run (CDC §3.2).

    docker stack config -c stacks/X.yml -c stacks/overrides/single-node.yml \\
      | python3 scripts/lib/single-node.py > .rendered/single-X.yml

Why a filter and not just the override file
-------------------------------------------
Two properties of `docker stack config` make a pure override file insufficient,
and both were found by inspecting the merged output rather than by assuming:

1. **Placement constraints are APPENDED, never replaced.** An override with
   `constraints: []` changes nothing, and one with a satisfiable constraint
   yields `['node.labels.cassandra == 1', 'node.role == manager']` — the
   original is still there, and the service stays Pending forever on a node
   that carries no such label. There is no override syntax that removes a
   constraint, so it has to be done here.

2. **An override file ADDS its services to every stack it is merged with.** One
   override listing all forty services would inject `minio: {deploy: ...}` into
   the `data` stack — a service with no image, which `docker stack deploy`
   rejects. Dropping the services that carry no image is what lets a single
   authored override file cover the five stacks, as the CDC's file tree asks.

What it changes, and nothing else:
  * services with no `image` are removed (they belong to another stack);
  * `deploy.placement.constraints` is removed;
  * `deploy.placement.max_replicas_per_node` is removed — with one node it
    would cap a 2-replica service at 1 and leave the second task Pending;
  * `deploy.placement.preferences` is removed: spreading over one node is
    meaningless and Swarm rejects some forms of it;
  * every `$` is re-escaped as `$$`, because the output is fed back to
    `docker stack deploy`, which interpolates a second time (see
    `escape_dollars`).

Everything else — replicas, resources, secrets, configs, networks, volumes —
comes from the stack and its override, unchanged. This filter must stay a
filter: the moment it starts *deciding* things, single-node mode stops testing
the same definitions production runs.
"""

from __future__ import annotations

import sys

import yaml


def escape_dollars(node: object) -> object:
    """Re-escape `$` as `$$` throughout the tree.

    `docker stack config` has ALREADY performed interpolation, so its output
    contains real dollars: `$(cat /run/secrets/…)` in a healthcheck, `($|/)` in
    a node-exporter regex. `docker stack deploy` interpolates its input again,
    and chokes on both — "invalid interpolation format … you may need to escape
    any $ with another $".

    Doubling every dollar is the exact inverse of that second interpolation, so
    what Swarm finally receives is byte-for-byte what the stack meant. Found by
    re-validating the filtered file rather than by trusting the pipeline.
    """
    if isinstance(node, str):
        return node.replace("$", "$$")
    if isinstance(node, list):
        return [escape_dollars(item) for item in node]
    if isinstance(node, dict):
        return {key: escape_dollars(value) for key, value in node.items()}
    return node


def strip_placement(deploy: dict) -> None:
    """Remove what pins a service to a node that does not exist here."""
    placement = deploy.get("placement")
    if not isinstance(placement, dict):
        return
    for key in ("constraints", "max_replicas_per_node", "preferences"):
        placement.pop(key, None)
    # An empty `placement:` is valid but noisy; drop it so the rendered file
    # reads like something a person would have written.
    if not placement:
        deploy.pop("placement", None)


def main() -> int:
    doc = yaml.safe_load(sys.stdin) or {}
    services = doc.get("services") or {}

    kept: dict[str, dict] = {}
    dropped: list[str] = []
    for name, spec in services.items():
        if not isinstance(spec, dict) or not spec.get("image"):
            # Contributed by the override file for a different stack.
            dropped.append(name)
            continue
        deploy = spec.get("deploy")
        if isinstance(deploy, dict):
            strip_placement(deploy)
        kept[name] = spec

    if not kept:
        print("single-node: no service left after filtering", file=sys.stderr)
        return 1

    doc["services"] = kept

    # Volumes, configs, secrets and networks are left exactly as they are: a
    # single-node deployment uses the same NFS exports, the same external
    # networks and the same Docker secrets as the real cluster. That is the
    # point — anything this filter changed would no longer be under test.
    # The whole document, not only the services: a volume driver option or a
    # config name could carry a dollar just as easily.
    yaml.safe_dump(escape_dollars(doc), sys.stdout, default_flow_style=False, sort_keys=False)

    if dropped:
        print(
            f"single-node: {len(dropped)} service(s) from other stacks dropped: "
            + ", ".join(sorted(dropped)),
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())

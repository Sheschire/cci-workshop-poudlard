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
    `escape_dollars`);
  * NFS-backed volumes become plain local volumes (see `delocalise_nfs`) —
    without this, ten volumes fail to mount on a workstation that runs no NFS
    server, and GLPI, the metrics exporter and every backup job stay Pending.

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


def delocalise_nfs(doc: dict) -> dict[str, str]:
    """Turn every NFS-backed volume into a plain local one.

    On a single machine there is nothing to share: NFS exists in this platform
    for exactly one reason — two GLPI replicas on two different nodes must see
    the same attachments (ADR-0006). With one node, the export would have to be
    served by the very machine that mounts it, so `make single` would need an
    NFS server installed on the workstation. Without one, ten volumes fail to
    mount and GLPI, the metrics server and every backup job stay Pending.

    One subtlety that a naive rewrite gets wrong: `backup_metrics` (read-write,
    for the jobs) and `backup_metrics_ro` (read-only, for the nginx that serves
    them) are two volume DEFINITIONS pointing at the SAME export. Mapped to two
    independent local volumes, the jobs would write into one and the exporter
    would read the other — for ever empty, with no error anywhere. So volumes
    are grouped by their `device`, and the aliases are rewritten to the
    canonical name in every service that mounts them.

    Returns {alias: canonical} for the caller to report.
    """
    volumes = doc.get("volumes") or {}
    by_device: dict[str, list[str]] = {}
    for name, spec in volumes.items():
        opts = (spec or {}).get("driver_opts") or {}
        if opts.get("type") == "nfs":
            by_device.setdefault(str(opts.get("device", name)), []).append(name)

    if not by_device:
        return {}

    alias_of: dict[str, str] = {}
    for device, names in by_device.items():
        canonical = sorted(names)[0]
        for name in names:
            alias_of[name] = canonical
        # A local volume, and nothing else: the default driver, no options. The
        # mount-level `read_only` of each service is preserved and still does
        # its job, so the exporter still cannot write to what it publishes.
        volumes[canonical] = {"driver": "local"}
        for name in names:
            if name != canonical:
                volumes.pop(name, None)
        del device  # only used for grouping

    for spec in (doc.get("services") or {}).values():
        mounts = (spec or {}).get("volumes") or []
        for mount in mounts:
            if isinstance(mount, dict) and mount.get("source") in alias_of:
                mount["source"] = alias_of[mount["source"]]

    return {a: c for a, c in alias_of.items() if a != c}


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

    aliases = delocalise_nfs(doc)

    # Configs, secrets and networks are left exactly as they are: a single-node
    # deployment uses the same external networks and the same Docker secrets as
    # the real cluster. That is the point — anything else this filter changed
    # would no longer be under test.
    # The whole document, not only the services: a volume driver option or a
    # config name could carry a dollar just as easily.
    yaml.safe_dump(escape_dollars(doc), sys.stdout, default_flow_style=False, sort_keys=False)

    if dropped:
        print(
            f"single-node: {len(dropped)} service(s) from other stacks dropped: "
            + ", ".join(sorted(dropped)),
            file=sys.stderr,
        )
    if aliases:
        print(
            "single-node: NFS volumes turned local; "
            + ", ".join(f"{a} → {c}" for a, c in sorted(aliases.items())),
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())

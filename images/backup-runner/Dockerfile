# =============================================================================
# dockerwarts/backup-runner — the single image every backup job runs in.
#
#   make build   → ${REGISTRY}/dockerwarts/backup-runner:${IMAGE_TAG}
#
# Why one image for every job (CDC §7.7)
# --------------------------------------
# The jobs back up heterogeneous things — a SQL dump, Cassandra SSTables, an
# Elasticsearch snapshot, NFS files, a Prometheus TSDB — but they all do the
# same three things afterwards: push to restic, publish a metric, exit. One
# image means one restic version, one metric format, one set of credentials
# wiring, and one thing to keep patched.
#
# Contents:
#   restic          the universal backup tool (encryption, dedup, prune, check)
#   mariadb-client  mariadb-dump for the SQL job
#   curl + jq       the Elasticsearch and Prometheus APIs
#   mc              MinIO client, for the off-site mirror
#   OpenJDK JRE + nodetool   Cassandra snapshots over JMX
# =============================================================================

# --- Stage 1: extract nodetool from the Cassandra image ----------------------
# `nodetool` is a shell script plus a handful of JARs. Copying just those from
# the official image is far smaller than installing Cassandra, and guarantees
# the tool matches the server version exactly — a nodetool from a different
# major version fails against the cluster with confusing errors.
FROM cassandra:5.0.9@sha256:d35e159439b302146f964919904f84fd3c2cebf347272b8cb8c4368c1cf200e5 AS cassandra-tools

# --- Stage 2: the MinIO client -----------------------------------------------
# `mc` is taken from its own official image rather than downloaded from
# dl.min.io. A URL cannot be pinned by content: the release archive is served
# over HTTPS from a CDN and verified by nothing. The image can be — tag AND
# digest, like every other image on this platform (CDC §10.2).
FROM minio/mc:RELEASE.2025-08-13T08-35-41Z@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727 AS mc

# --- Stage 3: runtime --------------------------------------------------------
FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

LABEL org.opencontainers.image.title="dockerwarts/backup-runner" \
      org.opencontainers.image.description="restic + mariadb-client + nodetool + mc, for every backup job" \
      org.opencontainers.image.source="https://github.com/Sheschire/cci-workshop-poudlard"

SHELL ["/bin/ash", "-o", "pipefail", "-c"]

# The Alpine packages are not version-pinned individually (DL3018): the base
# image is pinned BY DIGEST, and an Alpine digest pins the whole package index
# with it, so a rebuild of this exact Dockerfile installs exactly the same
# versions. Pinning each package as well would only guarantee build failures on
# the day Alpine moves a package forward inside the same release.
# hadolint ignore=DL3018
RUN set -eu; \
    apk add --no-cache \
        restic \
        mariadb-client \
        mariadb-connector-c \
        curl \
        jq \
        ca-certificates \
        bash \
        coreutils \
        tzdata \
        gzip \
        openjdk17-jre-headless \
        python3 \
    ; \
    # A dedicated unprivileged account. uid 10002 sits outside the host range.
    addgroup -g 10002 backup; \
    adduser -D -u 10002 -G backup -s /bin/bash backup; \
    mkdir -p /metrics /restic-cache; \
    chown backup:backup /metrics /restic-cache

# The MinIO client, for the off-site mirror job.
COPY --from=mc --chown=root:root --chmod=0555 /usr/bin/mc /usr/local/bin/mc

# nodetool, cqlsh and the JARs/Python libraries they need, from the Cassandra
# image. cqlsh is a Python script that adds the zipped drivers under lib/ to
# sys.path at startup, which is why lib/ and pylib/ come along; it is used by
# backup-cassandra.sh to capture the keyspace definition (replication strategy
# and factor), which `nodetool snapshot` does not record anywhere.
COPY --from=cassandra-tools /opt/cassandra/bin/nodetool /opt/cassandra/bin/nodetool
COPY --from=cassandra-tools /opt/cassandra/bin/cqlsh /opt/cassandra/bin/cqlsh
COPY --from=cassandra-tools /opt/cassandra/bin/cqlsh.py /opt/cassandra/bin/cqlsh.py
COPY --from=cassandra-tools /opt/cassandra/pylib /opt/cassandra/pylib
COPY --from=cassandra-tools /opt/cassandra/lib /opt/cassandra/lib
COPY --from=cassandra-tools /opt/cassandra/conf /opt/cassandra/conf

# The job scripts and the shared library. The build context is the REPOSITORY
# ROOT for this image (see scripts/build-images.sh and the root .dockerignore),
# because these scripts live under scripts/ as CDC §10.1 requires — not inside
# images/. 0555: readable and executable, writable by nobody, including root.
COPY --chown=root:root --chmod=0555 scripts/backup/ /opt/backup/

ENV PATH="/opt/cassandra/bin:/opt/backup:${PATH}" \
    CASSANDRA_HOME=/opt/cassandra \
    CASSANDRA_CONF=/opt/cassandra/conf \
    # restic keeps an index cache; on a fresh container every run would
    # re-download the index without it. A volume makes each run incremental.
    RESTIC_CACHE_DIR=/restic-cache \
    TZ=Europe/Paris

USER 10002:10002
WORKDIR /opt/backup

# No HEALTHCHECK: these are one-shot jobs driven by swarm-cronjob. A container
# that is *supposed* to exit must not be reported unhealthy for doing so.

# Overridden per job by the service `command:`.
CMD ["/bin/bash", "-c", "echo 'backup-runner: no job specified'; exit 1"]

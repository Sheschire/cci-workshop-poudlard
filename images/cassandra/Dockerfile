# =============================================================================
# dockerwarts/cassandra — Cassandra 5.0 with an in-JVM Prometheus JMX exporter.
#
#   make build          → ${REGISTRY}/dockerwarts/cassandra:${IMAGE_TAG}
#
# Why a home-made image (CDC §7.3)
# --------------------------------
# Cassandra exposes everything through JMX. The alternatives to embedding the
# exporter are worse:
#   * a separate jmx_exporter container would need the JMX port opened over the
#     network, with credentials, for every node — three more services and a new
#     attack surface;
#   * cassandra_exporter (third party) lags behind Cassandra releases.
# The in-JVM javaagent runs inside the process it measures, needs no network
# JMX at all, and exposes plain HTTP on :7070.
# =============================================================================

# --- Stage 1: fetch and verify the javaagent ---------------------------------
# A separate stage so that curl and the checksum tooling never reach the final
# image.
FROM cassandra:5.0.9@sha256:d35e159439b302146f964919904f84fd3c2cebf347272b8cb8c4368c1cf200e5 AS fetch

# Pinned version and SHA-256: an unpinned agent would change under us, and this
# JAR runs *inside* the database JVM with full access to it.
#
# 1.0.1 is the latest release published on Maven Central (checked 2026-09-07).
# The digest below was obtained by downloading the artefact and confirming it
# against the SHA-1 that Maven Central publishes next to it
# (f9c53eb0aa1828c3c9cd7647238563e43a4ed68c) — never copied from a third party.
# To bump the version, repeat that procedure; do not guess the value.
ARG JMX_EXPORTER_VERSION=1.0.1
ARG JMX_EXPORTER_SHA256=7d61f737fd661610ccc14aea79764faa1ea94a340cbc8f0029b3d2edea3d80c1

# The fetch stage runs as root only to use apt; it is discarded and never
# becomes part of the runtime image (which ends on `USER cassandra`).
# hadolint ignore=DL3002
USER root
# `bash -o pipefail`: the checksum verification is a pipe, and a failure in the
# left-hand side must fail the build rather than be masked by the exit status
# of `sha256sum`.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3008
RUN set -Eeuo pipefail; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates; \
    curl -fsSL -o /tmp/jmx_prometheus_javaagent.jar \
      "https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/${JMX_EXPORTER_VERSION}/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar"; \
    echo "${JMX_EXPORTER_SHA256}  /tmp/jmx_prometheus_javaagent.jar" | sha256sum -c - \
      || { echo "CHECKSUM MISMATCH — refusing to build. Update JMX_EXPORTER_SHA256 after verifying upstream."; exit 1; }; \
    apt-get purge -y curl; \
    apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*

# --- Stage 2: the runtime image ----------------------------------------------
FROM cassandra:5.0.9@sha256:d35e159439b302146f964919904f84fd3c2cebf347272b8cb8c4368c1cf200e5

LABEL org.opencontainers.image.title="dockerwarts/cassandra" \
      org.opencontainers.image.description="Cassandra 5.0 + in-JVM Prometheus JMX exporter" \
      org.opencontainers.image.source="https://github.com/Sheschire/cci-workshop-poudlard"

COPY --from=fetch --chown=root:root --chmod=0444 \
     /tmp/jmx_prometheus_javaagent.jar /opt/jmx/jmx_prometheus_javaagent.jar

# The exporter's own configuration (which MBeans to expose, how to name them)
# is mounted as a Swarm config at runtime, not baked in: tuning the metric set
# must not require rebuilding the image.
# The javaagent is wired in through JVM_OPTS in stacks/data.yml, alongside the
# heap settings, so that every JVM flag lives in one readable place.

# The upstream image already runs as `cassandra` (uid 999). Kept as-is:
# CDC §6.4 asks for a non-root user "when the image allows it", and this one
# does it correctly out of the box.
USER cassandra

# Documented, never published on a host: Prometheus scrapes it over the `data`
# overlay (internal + IPsec).
EXPOSE 7070

HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=5 \
  CMD nodetool status 2>/dev/null | awk '$1 == "UN" { found = 1 } END { exit found ? 0 : 1 }'

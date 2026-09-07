# =============================================================================
# dockerwarts/demo-producer — background sensor load (CDC §7.8).
#
#   make build   → ${REGISTRY}/dockerwarts/demo-producer:${IMAGE_TAG}
#
# Writes {site, sensor_id, ts, temperature, humidity} into Cassandra (at
# LOCAL_QUORUM) and into the `datalake-events` data stream, continuously.
#
# It exists for two reasons, and the second is the important one:
#   * the dashboards have something to show;
#   * during the chaos campaign its error counter is the platform's own
#     statement that production never stopped (CDC §8.2 n°5).
# =============================================================================

# --- Stage 1: build the dependency tree --------------------------------------
# Separate, so that pip and its cache never reach the runtime image, and so a
# code change does not re-resolve the dependencies.
FROM python:3.12-slim@sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea AS build

WORKDIR /build
COPY requirements.txt .

# gcc is needed to build the Cassandra driver's optional C extensions
# (libev-based reactor and the murmur3 token hasher). They are worth the build
# stage: the pure-Python murmur3 is roughly an order of magnitude slower, and
# it is on the path of EVERY token-aware write.
# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends gcc libev-dev libc6-dev; \
    pip install --no-cache-dir --prefix=/install -r requirements.txt; \
    rm -rf /var/lib/apt/lists/*

# --- Stage 2: runtime --------------------------------------------------------
FROM python:3.12-slim@sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea

LABEL org.opencontainers.image.title="dockerwarts/demo-producer" \
      org.opencontainers.image.description="Sensor event generator for Cassandra and Elasticsearch" \
      org.opencontainers.image.source="https://github.com/Sheschire/cci-workshop-poudlard"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# libev4 only — the runtime half of what the build stage compiled against. No
# compiler, no headers.
# hadolint ignore=DL3008
RUN set -Eeuo pipefail; \
    apt-get update; \
    apt-get install -y --no-install-recommends libev4 curl; \
    rm -rf /var/lib/apt/lists/*; \
    # A dedicated unprivileged account (CDC §6.4). uid 10003 sits outside the
    # host's range, so a volume mounted by accident cannot be written as a
    # real user.
    groupadd --gid 10003 producer; \
    useradd --uid 10003 --gid 10003 --no-create-home --shell /usr/sbin/nologin producer

COPY --from=build /install /usr/local
COPY --chown=root:root --chmod=0444 app/ /app/app/

WORKDIR /app
USER 10003:10003

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1
# DONTWRITEBYTECODE: the root filesystem is read-only at runtime
# (stacks/demo.yml), so Python must not try to write .pyc files.

SHELL ["/bin/sh", "-c"]

# Prometheus metrics, scraped over the `monitoring` overlay. Never published.
EXPOSE 8000

# The metrics endpoint is the healthcheck: it proves the process is alive AND
# that its HTTP server answers, which is the only thing a scrape needs. A
# deeper check — "is Cassandra reachable?" — would be wrong here: a producer
# that cannot reach Cassandra must keep running and keep COUNTING THE ERRORS,
# not be restarted into a loop that resets the counter this service exists for.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -sf http://127.0.0.1:8000/metrics >/dev/null || exit 1

CMD ["python", "-m", "app.main"]

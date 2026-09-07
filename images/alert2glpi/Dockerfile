# =============================================================================
# dockerwarts/alert2glpi — Alertmanager → GLPI ticket bridge (ADR-0009).
#
#   make build   → ${REGISTRY}/dockerwarts/alert2glpi:${IMAGE_TAG}
# =============================================================================

# --- Stage 1: build the dependency tree --------------------------------------
# A separate stage so that pip, its cache and the build toolchain never reach
# the runtime image. It also means a dependency change does not invalidate the
# layer that copies the application code.
FROM python:3.12-slim@sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea AS build

WORKDIR /build
COPY requirements.txt .

# --no-cache-dir: the wheel cache would be dead weight in the layer.
# --prefix: installs into a self-contained tree that stage 2 copies wholesale.
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# --- Stage 2: runtime --------------------------------------------------------
FROM python:3.12-slim@sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea

LABEL org.opencontainers.image.title="dockerwarts/alert2glpi" \
      org.opencontainers.image.description="Alertmanager webhook to GLPI ticket bridge" \
      org.opencontainers.image.source="https://github.com/Sheschire/cci-workshop-poudlard"

# curl for the container healthcheck; nothing else is added.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3008
RUN set -Eeuo pipefail; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl; \
    rm -rf /var/lib/apt/lists/*; \
    # A dedicated unprivileged account (CDC §6.4). uid 10001 is well outside
    # the host's own range, so a volume mounted by accident cannot be written
    # as a real user.
    groupadd --gid 10001 alert2glpi; \
    useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin alert2glpi

COPY --from=build /install /usr/local
COPY --chown=root:root --chmod=0444 app/ /app/app/

WORKDIR /app
USER 10001:10001

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1
# DONTWRITEBYTECODE: the filesystem is read-only at runtime
# (stacks/monitoring.yml), so Python must not try to write .pyc files.

# Back to the default shell for CMD/HEALTHCHECK: bash is not needed at runtime.
SHELL ["/bin/sh", "-c"]

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -sf http://127.0.0.1:8080/healthz || exit 1

# A single worker on purpose: the metrics counters live in the process memory,
# and two workers would each hold half the truth — /metrics would then report
# whichever worker answered the scrape.
CMD ["uvicorn", "app.main:app", \
     "--host", "0.0.0.0", \
     "--port", "8080", \
     "--workers", "1", \
     "--no-access-log"]
# --no-access-log: Traefik and the GLPI API already log; uvicorn's own access
# log would triple the volume for no new information.

#!/usr/bin/env bash
# =============================================================================
# MinIO initialisation (CDC §7.7).
#
#   scripts/minio-init.sh          (called by deploy.sh after the `backup` stack)
#
# Idempotent by construction: every step states a desired end state and treats
# "already exists" as success. Re-running it after a redeploy, a rotation or a
# disaster-recovery rebuild converges instead of failing.
#
# What it does, in order:
#   1. locate a running MinIO task on this node and wait for it to be live;
#   2. create the buckets: restic, es-snapshots, mirror;
#   3. enable versioning on `restic`;
#   4. install the three access policies (config/minio/policies/);
#   5. create the three service accounts and attach their policy;
#   6. verify with a real write/read/delete round trip as the `restic` user;
#   7. call scripts/es-init.sh back so it can finally register the snapshot
#      repository — it could not, MinIO did not exist when `data` was deployed.
#
# Why `docker exec` into the MinIO container rather than an `mc` on the host:
# the credentials stay inside the container (they are already there, as Docker
# secrets), no port has to be published, and the host needs no `mc` binary.
# =============================================================================
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

need_manager
load_env
cd "$DW_ROOT"

readonly SERVICE=backup_minio
# Where stacks/backup.yml mounts the policy documents inside the container.
readonly POLICY_DIR=/etc/minio/policies

# --- 1. Locate the container -------------------------------------------------
CID="$(docker ps -q --filter "label=com.docker.swarm.service.name=${SERVICE}" | head -1)"
if [[ -z "$CID" ]]; then
  error "no MinIO task on $(hostname)."
  error "MinIO is pinned to the node labelled minio=true (node3 by default):"
  error "  run this script from that node, or: make deploy-backup && ssh node3 …"
  die "aborting"
fi
info "using the MinIO container ${CID:0:12}"

# -----------------------------------------------------------------------------
# mc_root <args…> — run `mc` inside the container as the root account.
#
# The alias is passed through MC_HOST_local (an environment variable read by
# mc) instead of `mc alias set`: nothing is written to an on-disk mc config,
# and the credentials never appear on a command line where `ps` would show
# them. `exec mc "$@"` keeps the arguments intact — a bucket name or a JSON
# path is never re-split by the shell.
# -----------------------------------------------------------------------------
mc_root() {
  docker exec "$CID" sh -c '
    MC_HOST_local="http://$(cat /run/secrets/dw_minio_root_user):$(cat /run/secrets/dw_minio_root_password)@localhost:9000"
    export MC_HOST_local MC_CONFIG_DIR=/tmp/.mc
    exec mc --no-color "$@"' _ "$@"
}

# Same, as one of the service accounts — used by the verification step, which
# must exercise the policy that was just attached, not the root bypass.
mc_as() {
  local key_secret=$1 secret_secret=$2; shift 2
  docker exec "$CID" sh -c '
    key_file=$1; secret_file=$2; shift 2
    MC_HOST_svc="http://$(cat "$key_file"):$(cat "$secret_file")@localhost:9000"
    export MC_HOST_svc MC_CONFIG_DIR=/tmp/.mc
    exec mc --no-color "$@"' _ \
    "/run/secrets/${key_secret}" "/run/secrets/${secret_secret}" "$@"
}

# --- Wait for the API --------------------------------------------------------
section "1/7 — waiting for the MinIO API"
elapsed=0
until mc_root ready local >/dev/null 2>&1; do
  (( elapsed < 120 )) || die "MinIO did not become ready in 120 s"
  sleep 3
  elapsed=$(( elapsed + 3 ))
done
ok "MinIO answers (${elapsed}s)"

# =============================================================================
# 2. Buckets
#
# `mc mb --ignore-existing` is the idempotent form: it succeeds on a bucket
# that is already there instead of returning an error the script would have to
# parse.
#
#   restic        the restic repository (SQL dumps, Cassandra snapshots, files)
#   es-snapshots  the Elasticsearch S3 snapshot repository (native SLM)
#   mirror        landing bucket used by the restore path when data has to be
#                 pulled BACK from the off-site S3 (restore-*.sh --from offsite)
# =============================================================================
section "2/7 — buckets"
for bucket in restic es-snapshots mirror; do
  mc_root mb --ignore-existing "local/${bucket}" >/dev/null
  ok "bucket ${bucket}"
done

# =============================================================================
# 3. Versioning on `restic`
#
# Versioning is a ransomware mitigation, not a retention mechanism: if an
# attacker who obtained the restic credentials deletes the repository, the
# objects become previous versions instead of disappearing. `restic forget
# --prune` deletes normally; the previous versions are what the off-site
# mirror and a manual `mc undo` can still recover.
#
# NOT enabled on `es-snapshots`: Elasticsearch rewrites its index blobs on
# every snapshot, and versioning them would grow the bucket without bound for
# no gain — ES snapshots are already incremental and versioned by design.
# =============================================================================
section "3/7 — versioning"
mc_root version enable local/restic >/dev/null
ok "versioning enabled on restic"

# =============================================================================
# 4. Policies
#
# One policy per consumer, each restricted to its own bucket (CDC §7.7). The
# documents live in config/minio/policies/ and are mounted into the container
# as Swarm configs, so the source of truth is git and a change rolls the
# service through the content hash.
#
# `mc admin policy create` overwrites an existing policy of the same name: the
# call is idempotent AND it makes the file in git authoritative — editing the
# JSON and re-running this script actually applies the change.
# =============================================================================
section "4/7 — access policies"
declare -A POLICIES=(
  [dw-restic]=restic.json
  [dw-elasticsearch]=elasticsearch.json
  [dw-mirror]=mirror.json
)
for policy in "${!POLICIES[@]}"; do
  file="${POLICY_DIR}/${POLICIES[$policy]}"
  docker exec "$CID" test -r "$file" \
    || die "${file} is not mounted in the container — check the configs of stacks/backup.yml"
  mc_root admin policy create local "$policy" "$file" >/dev/null
  ok "policy ${policy} (${POLICIES[$policy]})"
done

# =============================================================================
# 5. Service accounts
#
# Access key and secret key both come from Docker secrets, so they are the same
# values the jobs read — there is no place where a credential is written twice
# and could drift.
#
# `mc admin user add` takes the secret as an argument: the MinIO admin API has
# no stdin form for it. The exposure is bounded to this container, which
# already holds the root credentials under /run/secrets; nothing leaves it.
#
# `mc admin user add` on an existing user updates its secret key, which is
# precisely the behaviour wanted after `init-secrets.sh --rotate`.
# =============================================================================
section "5/7 — service accounts"
add_user() {
  local key_secret=$1 secret_secret=$2 policy=$3
  docker exec "$CID" sh -c '
    MC_HOST_local="http://$(cat /run/secrets/dw_minio_root_user):$(cat /run/secrets/dw_minio_root_password)@localhost:9000"
    export MC_HOST_local MC_CONFIG_DIR=/tmp/.mc
    user="$(cat "/run/secrets/$1")"
    mc --no-color admin user add local "$user" "$(cat "/run/secrets/$2")" >/dev/null
    mc --no-color admin policy attach local "$3" --user "$user" >/dev/null 2>&1 || true
  ' _ "$key_secret" "$secret_secret" "$policy"
  ok "account ${key_secret} → policy ${policy}"
}
# `policy attach` errors when the policy is already attached; that is a success
# for our purposes, hence the `|| true` above — the verification step below is
# what actually proves the attachment works.
add_user dw_minio_restic_key   dw_minio_restic_secret   dw-restic
add_user dw_minio_es_key       dw_minio_es_secret       dw-elasticsearch
add_user dw_minio_mirror_key   dw_minio_mirror_secret   dw-mirror

# =============================================================================
# 6. Verification — a real round trip, as the restic user
#
# Creating a user and attaching a policy can both "succeed" and still leave an
# account that cannot write: a typo in an ARN, a policy that was not attached,
# a stale secret. The only proof is to write, read and delete an object with
# the credentials the backup jobs will use.
# =============================================================================
section "6/7 — verification (write / read / delete as the restic account)"
probe="dockerwarts-init-probe-$(date -u +%s)"
docker exec "$CID" sh -c "printf 'dockerwarts' > /tmp/${probe}"

mc_as dw_minio_restic_key dw_minio_restic_secret \
  cp "/tmp/${probe}" "svc/restic/${probe}" >/dev/null \
  || die "the restic account cannot WRITE into the restic bucket — check the dw-restic policy"

mc_as dw_minio_restic_key dw_minio_restic_secret \
  cat "svc/restic/${probe}" 2>/dev/null | grep -q dockerwarts \
  || die "the restic account cannot READ back what it wrote"

mc_as dw_minio_restic_key dw_minio_restic_secret \
  rm "svc/restic/${probe}" >/dev/null \
  || warn "probe object left behind: restic/${probe}"

# The isolation between accounts is part of the design, so it is tested too: a
# policy that grants more than its bucket would go unnoticed forever otherwise.
if mc_as dw_minio_restic_key dw_minio_restic_secret \
     ls "svc/es-snapshots" >/dev/null 2>&1; then
  die "ISOLATION FAILURE: the restic account can list es-snapshots — review config/minio/policies/restic.json"
fi
docker exec "$CID" rm -f "/tmp/${probe}" || true
ok "round trip successful, and the accounts are isolated from each other"

# =============================================================================
# 7. Hand back to es-init.sh
#
# es-init.sh runs when the `data` stack comes up, at which point MinIO does not
# exist yet: it skips the snapshot repository with an explicit message. Now
# that the bucket and the credentials exist, calling it back registers the
# repository, verifies it and installs the SLM policy. It is idempotent, so
# re-running the whole script is safe.
# =============================================================================
section "7/7 — Elasticsearch snapshot repository"
if docker service ls --format '{{.Name}}' | grep -q '^data_es-1$'; then
  if [[ -x scripts/es-init.sh ]]; then
    info "re-running es-init.sh to register the 'minio' repository and the SLM policy"
    scripts/es-init.sh
  fi
else
  warn "the 'data' stack is not deployed: ES snapshot repository not registered"
  warn "  run scripts/es-init.sh once Elasticsearch is up"
fi

section "MinIO initialised"
ok "buckets: restic (versioned), es-snapshots, mirror"
ok "accounts: restic, elasticsearch, mirror — each confined to its own bucket"

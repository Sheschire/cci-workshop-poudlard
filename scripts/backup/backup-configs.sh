#!/usr/bin/env bash
# =============================================================================
# backup-configs — the state of the cluster itself (CDC §9.1, 05:00 UTC).
#
# Every *definition* on this platform is in git: the stacks, the Ansible roles,
# the configuration files. What is NOT in git is the RUNTIME state that the
# definitions produced — which digest each service actually resolved to, which
# node carries which label, which overlay got which subnet, which config and
# secret objects each service references, and where Elasticsearch's ILM and SLM
# stand.
#
# That is what a rebuild needs in order to be a rebuild of *this* cluster
# rather than of a plausible one, and it is what makes the "what changed?"
# question answerable after an incident.
#
# The Docker API is reached through the READ-ONLY socket proxy (CDC §6.4).
# `/configs` and `/secrets` are deliberately not exposed there — /configs would
# hand out the content of every config object. Their NAMES are captured anyway,
# from the service definitions that reference them, which is what a rebuild
# actually needs: the content comes back from git, the secrets from the vault.
# =============================================================================
set -Eeuo pipefail
# The library lives at /opt/backup/lib.sh inside the container; the directive
# below points the linter at its source in the repository.
# shellcheck source=scripts/backup/lib.sh
source /opt/backup/lib.sh

job_start backup-configs
restic_env
ensure_repo

readonly OUT="/tmp/cluster-state"
rm -rf "$OUT"
mkdir -p "$OUT"

dump() {
  local name=$1 path=$2
  if docker_api "$path" | jq '.' > "${OUT}/${name}.json" 2>/dev/null; then
    ok "${name}.json ($(wc -c < "${OUT}/${name}.json") bytes)"
  else
    die "the Docker API refused ${path} — check the allow-list of docker-socket-proxy"
  fi
}

# --- 1. Swarm state ----------------------------------------------------------
info "collecting the Swarm state"
dump services /services
dump tasks    /tasks
dump nodes    /nodes
dump networks /networks
dump info     /info

# --- 2. Derived, human-readable views ----------------------------------------
# The raw JSON is complete but unreadable at 3 a.m. These three files are what
# an operator actually opens during a rebuild.
info "deriving the operator views"

# Which image digest each service really runs. `docker service ls` shows the
# tag; only this shows what the tag pointed at on the day it was deployed —
# the difference between "redeploy" and "redeploy the same thing".
jq -r '.[] | [.Spec.Name, .Spec.TaskTemplate.ContainerSpec.Image] | @tsv' \
  "${OUT}/services.json" | sort > "${OUT}/images.tsv"

# The placement labels. Rebuilding a node without them silently reschedules
# nothing: the pinned services stay Pending forever.
jq -r '.[] | [.Description.Hostname, (.Spec.Labels | to_entries | map("\(.key)=\(.value)") | join(","))] | @tsv' \
  "${OUT}/nodes.json" | sort > "${OUT}/node-labels.tsv"

# Which config and secret objects each service consumes.
jq -r '
  .[] as $s
  | ($s.Spec.TaskTemplate.ContainerSpec.Configs // [] | .[] | [$s.Spec.Name, "config", .ConfigName]),
    ($s.Spec.TaskTemplate.ContainerSpec.Secrets // [] | .[] | [$s.Spec.Name, "secret", .SecretName])
  | @tsv' "${OUT}/services.json" | sort > "${OUT}/config-secret-refs.tsv"

# --- 3. Elasticsearch lifecycle state ----------------------------------------
# ILM and SLM are configuration that lives *inside* Elasticsearch. es-init.sh
# recreates them from git, but knowing what was actually applied — and which
# ILM step each index had reached — is what tells you, after a restore, whether
# a missing index was deleted by policy or lost.
info "collecting the Elasticsearch lifecycle state"
ES_PASSWORD="$(read_secret dw_es_elastic_password)"
es_get() {
  curl -sS --fail-with-body --max-time 60 --config - \
       "http://${ES_HOST:-es-1}:9200${1}" <<EOF
user = "elastic:${ES_PASSWORD}"
EOF
}
es_ok=1
for endpoint in \
    "_ilm/policy:ilm-policies" \
    "_slm/policy:slm-policies" \
    "_snapshot/minio/_all:snapshots" \
    "_index_template:index-templates" \
    "_data_stream:data-streams" \
    "_cat/indices?format=json&h=index,health,status,docs.count,store.size:indices"; do
  path="/${endpoint%%:*}"
  name="${endpoint##*:}"
  if es_get "$path" | jq '.' > "${OUT}/es-${name}.json" 2>/dev/null; then
    ok "es-${name}.json"
  else
    warn "Elasticsearch did not answer ${path}"
    es_ok=0
  fi
done
(( es_ok )) || warn "part of the Elasticsearch state is missing from this archive"

# --- 4. A README, because a JSON dump six months from now is not obvious ------
# The backticks below are Markdown code spans, not command substitutions: the
# single quotes are exactly what keeps them literal.
# shellcheck disable=SC2016
{
  printf '# État du cluster Dockerwarts — %s\n\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  printf 'Produit par `scripts/backup/backup-configs.sh` (CDC §9.1).\n\n'
  printf 'Ce répertoire ne contient **aucun secret** : ni contenu de config,\n'
  printf 'ni valeur de secret. Il décrit ce que le cluster exécutait, pas ce\n'
  printf 'qui lui permet de le faire — cela vient de git et du coffre.\n\n'
  printf '| Fichier | Contenu |\n|---|---|\n'
  printf '| `services.json` | définition complète de chaque service Swarm |\n'
  printf '| `tasks.json` | tâches en cours, avec leur nœud et leur état |\n'
  printf '| `nodes.json` | nœuds, rôles, labels, ressources |\n'
  printf '| `networks.json` | réseaux overlay, sous-réseaux, options |\n'
  printf '| `info.json` | version Docker, état du Raft, ID du nœud |\n'
  printf '| `images.tsv` | **digest réellement déployé** par service |\n'
  printf '| `node-labels.tsv` | labels de placement (à réappliquer avant tout redéploiement) |\n'
  printf '| `config-secret-refs.tsv` | objets config/secret référencés par service |\n'
  printf '| `es-*.json` | ILM, SLM, snapshots, templates, data streams, indices |\n'
} > "${OUT}/README.md"

# --- 5. Archive --------------------------------------------------------------
restic backup "$OUT" \
  --tag configs \
  --host dockerwarts \
  --quiet

job_size "$(restic_snapshot_size configs)"
rm -rf "$OUT"
ok "cluster state archived"

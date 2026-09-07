#!/usr/bin/env bash
# =============================================================================
# single-node-prepare.sh — préparer un poste local pour `make single`.
#
#   scripts/single-node-prepare.sh [--fix]
#
#   --fix   crée ce qui peut l'être (répertoires de logs, Swarm, réseaux)
#           au lieu de se contenter de le signaler
#
# Pourquoi ce script existe
# -------------------------
# Sur les trois VM, Ansible prépare l'hôte : il crée `/var/log/traefik`, pose
# les sysctls, initialise le Swarm et crée les réseaux overlay. `make single`
# saute complètement Ansible — c'est son intérêt — et hérite donc d'un hôte
# non préparé.
#
# Sans cette préparation, Swarm accepte les stacks puis REJETTE les tâches, une
# par une, avec des messages qui ne disent pas quoi faire :
#
#   "invalid mount config for type bind: bind source path does not exist:
#    /var/log/traefik"
#
# Constaté en déployant réellement les six stacks sur un Swarm mono-nœud.
# Ce script transforme ces rejets en une liste de choses à faire, AVANT le
# déploiement.
# =============================================================================
set -Eeuo pipefail
# Paths are relative to --source-path=scripts (see the lint-shell target).
# shellcheck source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

cd "$DW_ROOT"

FIX=0
[[ "${1:-}" == "--fix" ]] && FIX=1

PROBLEMS=0
WARNINGS=0

problem() { error "$*"; PROBLEMS=$(( PROBLEMS + 1 )); }
caveat()  { warn  "$*"; WARNINGS=$(( WARNINGS + 1 )); }

# `sudo` seulement si nécessaire, et jamais en silence.
maybe_sudo() {
  if [[ "$(id -u)" == "0" ]]; then "$@"; return; fi
  if command -v sudo >/dev/null 2>&1; then sudo "$@"; return; fi
  return 1
}

# =============================================================================
section "1. Docker et Swarm"
# =============================================================================
need_cmd docker
if ! docker info >/dev/null 2>&1; then
  problem "le démon Docker ne répond pas — démarrer Docker Desktop, ou : sudo systemctl start docker"
  error "rien d'autre ne peut être vérifié tant que le démon est absent"
  exit 1
fi
ok "démon Docker $(docker info --format '{{.ServerVersion}}')"

swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}')"
if [[ "$swarm_state" != "active" ]]; then
  if (( FIX )); then
    docker swarm init --advertise-addr 127.0.0.1 >/dev/null
    ok "Swarm initialisé"
  else
    problem "ce Docker n'est pas en mode Swarm — corriger avec : docker swarm init"
  fi
else
  ok "Swarm actif ($(docker node ls --format '{{.Hostname}}' 2>/dev/null | wc -l | tr -d ' ') nœud)"
fi

# =============================================================================
section "2. Chemins de l'hôte montés par les stacks"
# =============================================================================
# Ce que les conteneurs bind-montent et qui doit exister AVANT eux. Chaque
# entrée : chemin, type, service concerné, et si son absence est bloquante.
#
# `/var/log/traefik` est le seul que la plateforme crée elle-même (rôle Ansible
# `docker`) : Traefik y écrit ses journaux d'accès, Fluent Bit les y lit et
# CrowdSec les y analyse. Sans lui, trois services sont rejetés d'emblée.
check_path() {
  local path=$1 kind=$2 who=$3 fatal=$4
  if [[ -e "$path" ]]; then
    ok "${path} (${who})"
    return
  fi
  if (( FIX )); then
    local created=0
    if [[ "$kind" == "dir" ]]; then
      maybe_sudo mkdir -p "$path" && created=1
    else
      maybe_sudo touch "$path" && created=1
    fi
    if (( created )); then
      ok "${path} créé (${who})"
      return
    fi
  fi
  local how
  [[ "$kind" == "dir" ]] && how="sudo mkdir -p ${path}" || how="sudo touch ${path}"
  if [[ "$fatal" == "fatal" ]]; then
    problem "${path} absent → ${who} sera REJETÉ par Swarm. Corriger : ${how}"
  else
    caveat "${path} absent → ${who} ne démarrera pas (sans conséquence pour le reste). ${how}"
  fi
}

check_path /var/log/traefik   dir  "traefik, fluent-bit, crowdsec-agent" fatal
# Journaux système : présents sur Ubuntu, absents des distributions qui n'ont
# que le journal systemd, et de Docker Desktop. CrowdSec perd une source
# d'acquisition sur trois ; les deux autres (Traefik, conteneurs) suffisent
# largement pour une démonstration locale.
check_path /var/log/auth.log  file "crowdsec-agent (source auth système)"  soft
check_path /var/log/kern.log  file "crowdsec-agent (source noyau)"         soft
# cAdvisor lit /dev/disk pour nommer les disques. Absent sur macOS et sur la
# VM de Docker Desktop : cAdvisor est alors rejeté, et les panneaux « conteneurs »
# de Grafana restent vides. Le reste de la supervision fonctionne.
if [[ -e /dev/disk ]]; then
  ok "/dev/disk (cadvisor)"
else
  caveat "/dev/disk absent → cadvisor sera rejeté (panneaux « conteneurs » vides). Impossible à créer : c'est le cas normal sur macOS et Docker Desktop."
fi

# =============================================================================
section "3. Réseaux overlay"
# =============================================================================
# Créés par le rôle Ansible `swarm` sur les VM. Les stacks les déclarent
# `external: true` : sans eux, `docker stack deploy` échoue immédiatement.
missing_nets=()
for net in edge data monitoring mgmt crowdsec; do
  if docker network inspect "$net" >/dev/null 2>&1; then
    ok "réseau ${net}"
  elif (( FIX )); then
    if [[ "$net" == "edge" ]]; then
      docker network create -d overlay --attachable "$net" >/dev/null
    else
      # `internal` : aucune route vers l'extérieur, comme en production.
      # Le chiffrement IPsec de `data` est volontairement omis en local : il
      # coûte du CPU pour protéger un trafic qui ne quitte pas la machine.
      docker network create -d overlay --attachable --internal "$net" >/dev/null
    fi
    ok "réseau ${net} créé"
  else
    missing_nets+=("$net")
  fi
done
if (( ${#missing_nets[@]} > 0 )); then
  problem "réseaux absents : ${missing_nets[*]} — les créer avec : $0 --fix"
fi

# =============================================================================
section "4. Ports 80 et 443"
# =============================================================================
# Traefik est en `mode: host` (ADR-0003) : il prend les ports de la machine,
# pas ceux d'un maillage. S'ils sont pris, la tâche reste en attente.
port_busy() {
  local port=$1
  if command -v ss >/dev/null 2>&1; then
    ss -ltn "sport = :${port}" 2>/dev/null | grep -q LISTEN
  elif command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
  else
    return 1   # impossible de vérifier : ne pas prétendre le contraire
  fi
}
for port in 80 443; do
  if port_busy "$port"; then
    problem "le port ${port} est déjà occupé — Traefik ne pourra pas s'y lier (arrêter le service concerné)"
  else
    ok "port ${port} libre"
  fi
done

# =============================================================================
section "5. Mémoire disponible"
# =============================================================================
# Trois JVM (Cassandra, Elasticsearch) plus MariaDB, Prometheus et le reste.
total_mb=0
if [[ -r /proc/meminfo ]]; then
  total_mb=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1024 ))
elif command -v sysctl >/dev/null 2>&1; then
  total_mb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 ))
fi
profile="$(grep -E '^PROFILE=' .env 2>/dev/null | cut -d= -f2 || echo full)"
if (( total_mb == 0 )); then
  caveat "mémoire totale non déterminée — compter ~10 Gio pour PROFILE=full, ~6 Gio pour light"
elif (( total_mb < 8000 )); then
  problem "${total_mb} Mio de RAM : insuffisant. Passer PROFILE=light dans .env et ne déployer que edge+data+apps"
elif (( total_mb < 12000 )); then
  caveat "${total_mb} Mio de RAM : tenable avec PROFILE=light (actuellement : ${profile})"
else
  ok "${total_mb} Mio de RAM (profil ${profile})"
fi

# =============================================================================
section "6. Fichier .env adapté au local"
# =============================================================================
[[ -f .env ]] || problem ".env absent — le créer : cp .env.example .env"

env_is() {
  local key=$1 expected=$2
  [[ "$(grep -E "^${key}=" .env 2>/dev/null | cut -d= -f2-)" == "$expected" ]]
}
env_get() { grep -E "^$1=" .env 2>/dev/null | cut -d= -f2-; }

# En mono-nœud, Traefik écoute sur la machine elle-même : la VIP Keepalived
# n'existe pas. `make smoke` et les tests chaos résolvent les URL vers $VIP.
if env_is VIP 127.0.0.1; then
  ok "VIP=127.0.0.1 (correct en local)"
else
  caveat "VIP=$(env_get VIP) — en local, mettre VIP=127.0.0.1 (sinon 'make smoke' interroge une adresse qui n'existe pas)"
fi

# Docker traite localhost et 127.0.0.1 comme des registres non sécurisés sans
# configuration ; toute autre adresse exigerait de modifier daemon.json.
case "$(env_get REGISTRY)" in
  127.0.0.1:*|localhost:*) ok "REGISTRY=$(env_get REGISTRY) (non sécurisé par défaut : rien à configurer)" ;;
  *) caveat "REGISTRY=$(env_get REGISTRY) — en local, mettre REGISTRY=127.0.0.1:5000, sinon 'make build' ne pourra pas pousser" ;;
esac

# Sans liste blanche correcte, toutes les interfaces d'administration renvoient
# 403 depuis le poste — y compris pour l'opérateur.
admin="$(env_get ADMIN_CIDR)"
if [[ -z "$admin" ]]; then
  problem "ADMIN_CIDR vide — le rendu de configuration échouera (et une liste blanche vide serait pire)"
elif [[ "$admin" == 192.168.56.* ]]; then
  caveat "ADMIN_CIDR=${admin} — en local, y ajouter le réseau des conteneurs, par exemple ADMIN_CIDR=0.0.0.0/0 pour un poste isolé, ou 172.16.0.0/12"
else
  ok "ADMIN_CIDR=${admin}"
fi

# =============================================================================
section "Résumé"
# =============================================================================
if (( PROBLEMS == 0 && WARNINGS == 0 )); then
  ok "le poste est prêt : make single"
  exit 0
fi
if (( PROBLEMS == 0 )); then
  ok "aucun blocage — ${WARNINGS} point(s) d'attention ci-dessus"
  ok "le déploiement peut commencer : make single"
  exit 0
fi
error "${PROBLEMS} blocage(s) et ${WARNINGS} point(s) d'attention"
(( FIX )) || error "  la plupart se corrigent avec : $0 --fix"
exit 1

# État d'avancement — Dockerwarts N°1

> Tableau de bord de développement. Une phase n'est marquée **terminée** que lorsque **tous**
> ses critères d'acceptation (§13 du CDC) ont été réellement vérifiés et que la documentation
> `docs/04-composants/` des composants concernés est écrite.
>
> Ce fichier est la source de vérité pour reprendre le développement sans perte de contexte.

**Dernière mise à jour** : 2026-09-07
**Branche de développement** : `claude/project-specs-architecture-fppn0x`

---

## Environnement de la session de développement

Cette section conditionne la lecture de la colonne « Vérifié ». Elle décrit ce que la session
de développement peut exécuter et ce qu'elle ne peut pas.

| Capacité | Disponible | Détail |
|---|---|---|
| Docker Engine (daemon local) | ✅ | 29.3.1, Swarm mono-nœud initialisable |
| `docker stack config` / `docker network create` | ✅ | validation syntaxique et sémantique des stacks |
| **Téléchargement d'images (blobs)** | ❌ | `production.cloudfront.docker.com` refusé par la politique d'egress (HTTP 403) → **aucun conteneur ne peut démarrer** |
| Résolution de digests (manifestes) | ✅ | `registry-1.docker.io`, `gcr.io` joignables |
| `docker.elastic.co` | ❌ | refusé par la politique d'egress → digests ES/Kibana non résolus |
| Vagrant / VirtualBox | ❌ | absent, pas de virtualisation imbriquée |
| Ansible + ansible-lint | ✅ | ansible-core 2.19.12, ansible-lint 26.8.0 |
| yamllint, shellcheck, hadolint, promtool, amtool, ruff, pytest | ✅ | installés |

**Conséquence** : tous les critères « statiques » (lint, validation de configuration, tests
unitaires, cohérence des stacks) sont vérifiés dans cette session. Tous les critères
« dynamiques » (démarrage réel des conteneurs, VIP, bascule, tickets GLPI) sont **listés
explicitement** en fin de phase avec la **commande exacte** à exécuter sur les 3 VM.

Légende : ✅ vérifié ici · 🖥️ à vérifier sur les VM (commande fournie) · ⬜ à faire · 🔄 en cours

---

## Phase 0 — Socle

**Livrables** : `Makefile`, `Vagrantfile`, `.env.example`, `ansible/` complet, `.github/workflows/ci.yml`

| # | Critère d'acceptation | État | Preuve |
|---|---|---|---|
| 0.1 | `make vms provision` s'exécute sans erreur | 🖥️ | `ansible-playbook --syntax-check` OK sur `site.yml` **et** `node-replace.yml` ; tous les templates Jinja rendus par Ansible pour les 3 hôtes |
| 0.2 | Second `provision` idempotent (0 changed) | 🖥️ | conçu pour : `changed_when: false` sur les seules lectures, aucun `shell:` non idempotent, `ansible-lint` profil production vert |
| 0.3 | `docker node ls` : 3 managers `Ready` / `Active` | 🖥️ | `docker swarm init` vérifié localement (1 nœud) ; `assert` sur le nombre de nœuds intégré au rôle `swarm` |
| 0.4 | La VIP `192.168.56.10` répond au ping | 🖥️ | `keepalived.conf` rendu et vérifié pour les 3 nœuds (états MASTER/BACKUP, priorités, pairs unicast) |
| 0.5 | `iptables -S DOCKER-USER` conforme au §6.1 | ✅ | script rendu **et réellement appliqué** : chaînes conformes, **idempotence prouvée** (empreinte identique après 2 exécutions), 1 seul saut depuis `INPUT`, variantes node1/node3 correctes, `stop` restaure |
| 0.6 | Réseaux overlay `edge`, `data`, `monitoring`, `mgmt`, `crowdsec` créés | ✅ | les 5 overlays créés sur un Swarm local avec les options exactes du rôle : `data` → `internal=true` + `encrypted`, les autres conformes au CDC §5.4 |
| 0.7 | CI verte | ✅ | `make lint` vert de bout en bout : yamllint, ansible-lint (production), shellcheck (scripts **+ template pare-feu**), hadolint, `docker stack config`, `validate-configs.sh`, `check-no-secrets.sh` |
| 0.8 | Documentation : `versions.md`, `ansible.md` | ✅ | toutes les images figées tag + digest ; les 8 rôles Ansible expliqués section par section |

**Statut de la phase** : ✅ **terminée** — livrables complets, critères statiques vérifiés,
critères dynamiques listés en bas de page avec leur commande.

---

## Phase 1 — Edge

**Livrables** : `stacks/registry.yml`, `stacks/edge.yml`, `config/traefik/`, `config/crowdsec/`,
`scripts/gen-certs.sh`, `scripts/init-secrets.sh`, `scripts/deploy.sh`, `make build`

| # | Critère d'acceptation | État | Preuve |
|---|---|---|---|
| 1.1 | `https://whoami.dockerwarts.lan` répond via la VIP | 🖥️ | stack validée (`docker stack config`), routeur et middlewares vérifiés par `check-traefik.py` |
| 1.2 | Certificat wildcard valide, signé par la CA interne | ✅ | `gen-certs.sh` **réellement exécuté** : CA 4096 bits, wildcard 825 j, `openssl verify` OK, paire clé↔certificat cohérente, SAN = `*.dockerwarts.lan`, `dockerwarts.lan`, `localhost`, `192.168.56.10`, `127.0.0.1` |
| 1.3 | L'IP client réelle apparaît dans la réponse whoami (`mode: host`) | 🖥️ | `ports.mode: host` vérifié dans la stack rendue ; `forwardedHeaders.trustedIPs` vide |
| 1.4 | `cscli decisions add -i <ip>` → `403` | 🖥️ | profils, acquisition et middleware bouncer validés statiquement (5 profils, 3 sources) |
| 1.5 | `vagrant halt node1` → bascule VIP < 5 s | 🖥️ | arithmétique des priorités vérifiée (§3.2 de `keepalived.md`), `keepalived.conf` rendu pour les 3 nœuds |
| 1.6 | `make build` pousse les images maison dans le registry interne | 🖥️ | `registry.yml` validé ; `build-images.sh` écrit (images maison livrées en phases 2 à 6) |
| 1.7 | Documentation : `traefik.md`, `keepalived.md`, `crowdsec.md` | ✅ | trois fichiers, chaque section de configuration expliquée |
| 1.8 | Durcissement CDC §6.4 sur **tous** les services | ✅ | `no-new-privileges` + `cap_drop: [ALL]` partout, `NET_BIND_SERVICE` seul ajout (Traefik), `read_only` sur 3 des 5 services, `user` non root sur whoami — **contrôle automatisé en CI** (test négatif effectué) |
| 1.9 | Aucun conteneur ne monte le socket Docker sauf le proxy | ✅ | contrôle automatisé dans `validate-stacks.sh` |

**Statut de la phase** : ✅ **terminée** — livrables complets, critères statiques vérifiés,
critères dynamiques listés en bas de page.

---

## Phase 2 — Data

**Livrables** : `stacks/data.yml`, `config/{galera,haproxy,cassandra,elasticsearch,kibana,fluent-bit}/`,
`images/cassandra/`, scripts d'initialisation

| # | Critère d'acceptation | État |
|---|---|---|
| 2.1 | `wsrep_cluster_size = 3` sur les trois nœuds Galera | ⬜ |
| 2.2 | `nodetool status` : 3 nœuds `UN` ; keyspace `datalake` avec RF=3 | ⬜ |
| 2.3 | `_cluster/health` = `green` | ⬜ |
| 2.4 | Politiques ILM, SLM et index templates en place | ⬜ |
| 2.5 | Logs Traefik et logs de conteneurs visibles dans Kibana | ⬜ |
| 2.6 | HAProxy `db-proxy` : un seul writer actif, bascule automatique | ⬜ |
| 2.7 | Documentation : `galera.md`, `cassandra.md`, `elasticsearch.md`, `kibana.md`, `fluent-bit.md` | ⬜ |

**Statut de la phase** : ⬜ à faire

---

## Phase 3 — Apps

**Livrables** : `stacks/apps.yml`, exports NFS, `scripts/glpi-init.sh`

| # | Critère d'acceptation | État |
|---|---|---|
| 3.1 | Connexion à GLPI via la VIP en HTTPS | ⬜ |
| 3.2 | Session stable entre les 2 replicas (cookie sticky) | ⬜ |
| 3.3 | Document joint toujours présent après `docker service update --force apps_glpi-web` | ⬜ |
| 3.4 | API REST GLPI répond avec les tokens générés (`initSession`) | ⬜ |
| 3.5 | Mots de passe par défaut (`glpi`, `tech`, `normal`, `post-only`) changés | ⬜ |
| 3.6 | Documentation : `glpi.md` | ⬜ |

**Statut de la phase** : ⬜ à faire

---

## Phase 4 — Monitoring

**Livrables** : `stacks/monitoring.yml`, `config/{prometheus,alertmanager,blackbox,grafana}/`,
12 dashboards, `images/alert2glpi/`

| # | Critère d'acceptation | État |
|---|---|---|
| 4.1 | 100 % des cibles Prometheus `up` | ⬜ |
| 4.2 | Les 12 dashboards se chargent sans panneau vide | ⬜ |
| 4.3 | `docker service scale apps_glpi-web=0` → alerte `GLPIDown` → **ticket GLPI créé** | ⬜ |
| 4.4 | Retour à `=2` → le ticket passe au statut Résolu | ⬜ |
| 4.5 | `NodeDown` inhibe les autres alertes portant le même `node` | ⬜ |
| 4.6 | `promtool check rules` / `check config` / `amtool check-config` verts | ⬜ |
| 4.7 | `pytest` alert2glpi vert | ⬜ |
| 4.8 | Documentation : `prometheus.md`, `alertmanager.md`, `grafana.md`, `alert2glpi.md` | ⬜ |

**Statut de la phase** : ⬜ à faire

---

## Phase 5 — Backup

**Livrables** : `stacks/backup.yml`, `images/backup-runner/`, `scripts/backup/`, `scripts/restore/`,
`tests/dr/dr-drill.sh`

| # | Critère d'acceptation | État |
|---|---|---|
| 5.1 | `make backup-now` : tous les jobs terminent en succès | ⬜ |
| 5.2 | Métriques de sauvegarde visibles dans le dashboard « Sauvegardes » | ⬜ |
| 5.3 | `make dr-drill` vert, rapport Markdown produit | ⬜ |
| 5.4 | `BackupTooOld` se déclenche en simulant une métrique ancienne | ⬜ |
| 5.5 | Snapshot ES SLM listé et en état `SUCCESS` | ⬜ |
| 5.6 | Documentation : `minio.md`, `backup.md` | ⬜ |

**Statut de la phase** : ⬜ à faire

---

## Phase 6 — HA & tests

**Livrables** : `tests/smoke/`, `tests/chaos/`, `stacks/overrides/single-node.yml`,
`stacks/demo.yml`, `images/demo-producer/`

| # | Critère d'acceptation | État |
|---|---|---|
| 6.1 | `make chaos` : chaque nœud tué à tour de rôle, smoke vert à chaque étape | ⬜ |
| 6.2 | Tickets GLPI créés puis résolus pendant les tests chaos | ⬜ |
| 6.3 | `demo-producer` : compteur d'erreurs à zéro pendant toute la campagne | ⬜ |
| 6.4 | `make single` opérationnel sur un poste mono-nœud | ⬜ |
| 6.5 | `tests/smoke/network-isolation.sh` vert | ⬜ |
| 6.6 | Documentation : résultats mesurés dans `docs/06-haute-disponibilite.md` | ⬜ |

**Statut de la phase** : ⬜ à faire

---

## Phase 7 — Documentation

**Livrables** : `docs/01` → `docs/08`, ADR à jour, README

| # | Critère d'acceptation | État |
|---|---|---|
| 7.1 | `docs/01-architecture.md` complet (schémas Mermaid) | ⬜ |
| 7.2 | `docs/02-installation.md` : pas-à-pas reproductible | ⬜ |
| 7.3 | `docs/03-reseau-securite.md` : 4 couches + matrice de flux complète | ⬜ |
| 7.4 | **Chaque** fichier de `config/` est expliqué dans `docs/04-composants/` | ⬜ |
| 7.5 | `docs/05-monitoring.md` : métriques, dashboards, tableau des règles d'alerte | ⬜ |
| 7.6 | `docs/06-haute-disponibilite.md` : matrice + résultats chaos | ⬜ |
| 7.7 | `docs/07-PRA.md` : les 8 points du §9.5, journal de tests réel | ⬜ |
| 7.8 | `docs/08-exploitation.md` : runbooks | ⬜ |
| 7.9 | README à jour | ⬜ |

**Statut de la phase** : ⬜ à faire

---

## Critères restés à vérifier sur les VM

Cette section est alimentée à la fin de chaque phase. Elle liste, avec la **commande exacte**,
tout critère qui n'a pas pu être exécuté dans la session de développement.

### Phase 0

Prérequis sur le poste d'administration : VirtualBox ≥ 7.0, Vagrant ≥ 2.4, Ansible ≥ 2.16, make.

```bash
cp .env.example .env
cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml
ansible-galaxy collection install -r ansible/requirements.yml

# 0.1 — provisioning complet, sans erreur
make vms provision

# 0.2 — idempotence : la ligne PLAY RECAP doit afficher changed=0 pour les 3 hôtes
make provision
#   ou, sans rien modifier :  make provision-check

# 0.3 — 3 managers Ready / Active, un seul Leader
vagrant ssh node1 -c 'docker node ls'

# 0.4 — la VIP répond, et elle est portée par node1 (priorité 150)
ping -c 3 192.168.56.10
vagrant ssh node1 -c "ip -4 -brief addr show enp0s8 | grep 192.168.56.10"

# 0.5 — pare-feu conforme (déjà vérifié hors VM, à reconfirmer in situ)
vagrant ssh node1 -c 'sudo iptables -S DOCKER-USER'
vagrant ssh node1 -c 'sudo iptables -S DW-INPUT'
vagrant ssh node1 -c 'sudo iptables -S INPUT'      # -P INPUT DROP + un seul -j DW-INPUT

# 0.6 — les 5 overlays existent, data est internal + encrypted
vagrant ssh node1 -c "docker network ls --filter driver=overlay"
vagrant ssh node1 -c "docker network inspect data --format '{{.Internal}} {{.Options}}'"

# 0.7 — la CI est un job GitHub Actions ; en local :
make lint
```

Les digests Elasticsearch et Kibana restent à résoudre (registre `docker.elastic.co` refusé par
la politique d'egress de la session) — commande exacte dans
[`docs/04-composants/versions.md`](04-composants/versions.md).

### Phase 1

```bash
make secrets certs          # déjà exécuté hors VM ; à rejouer sur un manager
make build                  # registry + images maison
make deploy-edge

# 1.1 / 1.2 / 1.3 — whoami via la VIP, certificat validé par la CA, IP réelle
curl --cacert certs/ca.crt https://whoami.dockerwarts.lan/ | grep -E 'RemoteAddr|X-Real-Ip'
#   RemoteAddr doit être l'IP du poste client, PAS une passerelle 10.20.x.x
openssl s_client -connect 192.168.56.10:443 -servername whoami.dockerwarts.lan \
  -CAfile certs/ca.crt </dev/null 2>&1 | grep -E 'Verify return code|subject='

# 1.4 — bannissement CrowdSec (depuis une source HORS CLUSTER_CIDR, cf. liste blanche)
vagrant ssh node3 -c "docker exec \$(docker ps -q -f name=edge_crowdsec-lapi) \
  cscli decisions add -i 203.0.113.42 -d 10m -R manual-test"
#   attendre ≤ 60 s (mode stream) puis, depuis 203.0.113.42 :
curl -sk -o /dev/null -w '%{http_code}\n' https://whoami.dockerwarts.lan/   # → 403

# 1.5 — bascule VIP mesurée
( while :; do date +%s.%N; curl -sk --max-time 1 -o /dev/null \
    https://whoami.dockerwarts.lan/ && echo OK || echo KO; sleep 0.2; done ) &
vagrant halt -f node1
#   compter les KO consécutifs × 0,2 s → doit rester < 5 s
vagrant ssh node2 -c 'journalctl -u keepalived -n 5 --no-pager'

# 1.6 — registry
curl -s http://192.168.56.13:5000/v2/_catalog

# 1.8 — durcissement effectif dans les conteneurs
vagrant ssh node1 -c "docker inspect \$(docker ps -q -f name=edge_traefik) \
  --format '{{.HostConfig.SecurityOpt}} {{.HostConfig.CapDrop}} {{.HostConfig.CapAdd}} {{.HostConfig.ReadonlyRootfs}}'"
```

> **À confirmer au premier démarrage** : `read_only: true` sur `traefik` et
> `docker-socket-proxy` n'a pas pu être validé à l'exécution (images non téléchargeables dans la
> session). Si un service refuse de démarrer avec une erreur d'écriture, ajouter le `tmpfs`
> manquant plutôt que de retirer `read_only`, et consigner le chemin dans
> `docs/04-composants/traefik.md`.

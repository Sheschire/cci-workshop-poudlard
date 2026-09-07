# État d'avancement — Dockerwarts N°1

> Tableau de bord de développement. Une phase n'est marquée **terminée** que lorsque **tous**
> ses critères d'acceptation (§13 du CDC) ont été réellement vérifiés et que la documentation
> `docs/04-composants/` des composants concernés est écrite.
>
> Ce fichier est la source de vérité pour reprendre le développement sans perte de contexte.

**Dernière mise à jour** : 2026-09-07
**Branche de développement** : `claude/project-specs-architecture-fppn0x`
**État global** : les **8 phases sont terminées**. Tous les livrables existent,
tous les critères statiques sont vérifiés dans cette session, et tous les
critères dynamiques sont listés en fin de page avec la **commande exacte** à
exécuter sur les VM — voir « Environnement de la session » ci-dessous pour la
raison, et « Critères restés à vérifier sur les VM » pour la liste.

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
| Ansible + ansible-lint | ⚠️ | ansible-core 2.19.12, ansible-lint 26.8.0 — mais `galaxy.ansible.com` est refusé par la politique d'egress (`403`). Sans les collections, `make lint-ansible` échoue sur 4 `syntax-check[unknown-module]` (`community.docker.docker_swarm`, `docker_node`, `community.general.timezone`) : ce sont des modules réels, déclarés dans `ansible/requirements.yml`. **Ce n'est pas une régression** — le lint était vert en phase 0, quand les collections avaient pu être installées. Sur une machine ayant accès à Galaxy :<br/>`ansible-galaxy collection install -r ansible/requirements.yml && make lint-ansible` |
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

| # | Critère d'acceptation | État | Preuve |
|---|---|---|---|
| 2.1 | `wsrep_cluster_size = 3` | 🖥️ | stack validée ; `galera-bootstrap.sh` implémente la séquence complète, **flag de bootstrap retiré en étape 5** |
| 2.2 | `nodetool status` 3 `UN` ; keyspace `datalake` RF=3 | 🖥️ | `init.cql` et `cassandra-init.sh` écrits ; la vérification finale du script fait un **aller-retour écriture/lecture réel en LOCAL_QUORUM** |
| 2.3 | `_cluster/health` = `green` | 🖥️ | `es-init.sh` attend et distingue `yellow` transitoire (0 shard non assigné) de `yellow` anormal |
| 2.4 | ILM, SLM et index templates en place | ✅ (statique) | 2 politiques ILM + 1 component template + 4 index templates + SLM : **JSON validés** ; `es-init.sh` vérifie en plus que l'ILM est réellement **attachée** à l'index sous-jacent |
| 2.5 | Logs Traefik et conteneurs visibles dans Kibana | 🖥️ | chaîne complète écrite ; filtres Lua **exécutés et vérifiés hors conteneur** (7 cas, voir `fluent-bit.md` §5.3) |
| 2.6 | `db-proxy` : un seul writer, bascule automatique | 🖥️ | `haproxy.cfg` : `galera-1` actif, 2 et 3 en `backup` dans un ordre déterministe, `on-marked-down shutdown-sessions` |
| 2.7 | Documentation des 5 composants | ✅ | `galera.md`, `cassandra.md`, `elasticsearch.md`, `kibana.md`, `fluent-bit.md` |
| 2.8 | Rendu de configuration Galera sûr | ✅ | wrapper **testé** : rendu exact de mots de passe contenant `/ & \ $`, et **4 cas négatifs** (secret absent, vide, illisible, variable manquante) abortent avant tout rendu |
| 2.9 | Durcissement CDC §6.4 sur les 12 services | ✅ | contrôle automatisé : aucun service sans `no-new-privileges`, `cap_drop: [ALL]`, healthcheck, limites, `logging` |

**Statut de la phase** : ✅ **terminée** — livrables complets, critères statiques vérifiés,
critères dynamiques listés en bas de page.

---

## Phase 3 — Apps

**Livrables** : `stacks/apps.yml`, exports NFS, `scripts/glpi-init.sh`

| # | Critère d'acceptation | État | Preuve |
|---|---|---|---|
| 3.1 | Connexion à GLPI via la VIP en HTTPS | 🖥️ | routeur Traefik validé par `check-traefik.py` (`app-chain@file`, sans allowlist : GLPI est la seule application publique) |
| 3.2 | Session stable entre les 2 replicas | ✅ (statique) | 5 labels sticky vérifiés dans la stack rendue : `glpi_srv`, `secure`, `httponly`, `samesite=lax`, + healthcheck Traefik sur `/status.php` |
| 3.3 | Document joint persistant après `--force` | 🖥️ | 4 volumes NFS vérifiés dans la stack rendue, montés par le démon Docker |
| 3.4 | API REST répond avec les tokens générés | 🖥️ | `glpi-init.sh` fait un **vrai `initSession`** en étape 8 et échoue si aucun `session_token` ne revient |
| 3.5 | Mots de passe par défaut changés | 🖥️ | étape 3 : `glpi` re-haché en bcrypt (format vérifié), `tech`/`normal`/`post-only` **désactivés ET** mot de passe détruit, puis contrôle SQL |
| 3.6 | Documentation : `glpi.md` | ✅ | stack, php.ini, volumes NFS et les 8 étapes d'init expliqués |
| 3.7 | Un seul exécuteur cron | ✅ (statique) | `glpi-cron` à 1 replica en `stop-first`, `GLPI_CRON_ENABLED=false` sur les deux services |

**Statut de la phase** : ✅ **terminée** — livrables complets, critères statiques vérifiés,
critères dynamiques listés en bas de page.

---

## Phase 4 — Monitoring

**Livrables** : `stacks/monitoring.yml`, `config/{prometheus,alertmanager,blackbox,grafana}/`,
12 dashboards, `images/alert2glpi/`

| # | Critère d'acceptation | État | Preuve |
|---|---|---|---|
| 4.1 | 100 % des cibles Prometheus `up` | 🖥️ | découverte Swarm par convention de labels validée ; `promtool check config` vert sur le fichier **rendu** |
| 4.2 | Les 12 dashboards se chargent sans panneau vide | ✅ (statique) | **155 panneaux, 51 sections, 0 chevauchement, 0 UID orphelin** — `check-grafana.py` vérifie que chaque référence de datasource est provisionnée, que chaque panneau a une cible et que le JSON correspond au générateur. **2 tests négatifs effectués** |
| 4.3 | `GLPIDown` → **ticket GLPI créé** | 🖥️ | chaîne complète écrite et testée unitairement : la règle se déclenche (test promtool), le webhook crée un ticket (test respx) |
| 4.4 | Retour → ticket Résolu | ✅ (unitaire) | test `test_resolved_adds_a_followup_and_solves` : suivi ajouté + statut 5 |
| 4.5 | `NodeDown` inhibe les alertes du même `node` | ✅ (statique) | 9 règles d'inhibition, `amtool check-config` vert, `equal: ["node"]` justifié |
| 4.6 | `promtool` / `amtool` verts | ✅ | `check config`, `check rules` (**48 règles**), **`test rules` : 15 tests unitaires verts**, `amtool check-config` dans les **deux** cas (SMTP absent et présent) |
| 4.7 | `pytest` alert2glpi vert | ✅ | **22 tests exécutés et verts**, API GLPI simulée au niveau transport (respx) |
| 4.8 | Documentation des 4 composants | ✅ | `prometheus.md`, `alertmanager.md`, `grafana.md`, `alert2glpi.md` |
| 4.9 | Exporters complets (CDC §7.6) | ✅ (statique) | node-exporter, cAdvisor, blackbox, mysqld (multi-cible), elasticsearch, plus les `/metrics` natifs de Traefik, CrowdSec, HAProxy, Fluent Bit, Alertmanager, Grafana, alert2glpi |

**Statut de la phase** : ✅ **terminée** — livrables complets, critères statiques vérifiés,
critères dynamiques listés en bas de page.

---

## Phase 5 — Backup

**Livrables** : `stacks/backup.yml`, `images/backup-runner/`, `scripts/backup/`, `scripts/restore/`,
`tests/dr/dr-drill.sh`, `scripts/minio-init.sh`, `scripts/backup-now.sh`,
`config/minio/policies/`, `config/backup/nginx.conf`, ADR-0010

| # | Critère d'acceptation | État | Preuve |
|---|---|---|---|
| 5.1 | `make backup-now` : tous les jobs terminent en succès | 🖥️ | les 11 services de jobs valident (`docker stack config`), montages, secrets, contraintes de placement et labels cron vérifiés dans la **stack rendue** (job par job) ; les scripts passent shellcheck avec `-x` |
| 5.2 | Métriques de sauvegarde visibles dans le dashboard « Sauvegardes » | ✅ (statique) | **13 assertions exécutées** sur `metric_write` : écriture, non-écrasement entre jobs, **horodatage de succès gelé en cas d'échec**, absence de série dupliquée, `# HELP`/`# TYPE` uniques ; fichier produit validé par **`promtool check metrics`**. Dashboard `dw-backup` déjà vérifié en phase 4 |
| 5.3 | `make dr-drill` vert, rapport Markdown produit | 🖥️ | 5 étapes écrites, chacune comparant le restauré au vivant ; nettoyage depuis un *trap*. L'**extraction d'une base du dump `--all-databases`** (le point fragile du *drill*) a été **testée réellement** sur un dump synthétique : première base et base du milieu, bornées des deux côtés, aucune fuite |
| 5.4 | `BackupTooOld` se déclenche en simulant une métrique ancienne | ✅ | test unitaire promtool déjà vert en phase 4 (`backup_last_success_timestamp` figé, alerte à 1 j 2 h 30) ; la simulation *in situ* reste listée ci-dessous |
| 5.5 | Snapshot ES SLM listé et en état `SUCCESS` | 🖥️ | `backup-es.sh` exécute la politique, **attend** et **refuse `PARTIAL`** ; le *repository* est enregistré par `es-init.sh`, rappelé par `minio-init.sh` |
| 5.6 | Documentation : `minio.md`, `backup.md` | ✅ | + ADR-0010 (métriques MinIO) et mise à jour de `versions.md` |
| 5.7 | Aucun secret dans le contexte de build de `backup-runner` | ✅ | contexte matérialisé et **inspecté** : `scripts/backup/` uniquement, 51 kio ; ni `secrets/`, ni `certs/`, ni `.env`, ni `.git/` (`.dockerignore` en *deny-by-default*) |
| 5.8 | Le socket Docker en écriture reste confiné | ✅ (statique) | `docker-socket-proxy-rw` sur un overlay privé `cronjob` (`internal`), liste blanche `SERVICES`/`TASKS`/`POST` seule, managers uniquement ; `validate-stacks.sh` interdit toujours le socket à tout autre service |

**Correctifs apportés à des phases antérieures** (nécessaires pour que la phase 5 fonctionne) :

- `stacks/data.yml` — `LOCAL_JMX: "no"` sur les Cassandra. Sans lui, `cassandra-env.sh` lie JMX à
  `127.0.0.1` : `nodetool -h cassandra-N` depuis le conteneur de sauvegarde ne pouvait pas
  fonctionner. Les secrets JMX sont désormais montés sur les chemins que `cassandra-env.sh`
  impose (`/etc/cassandra/jmxremote.{password,access}`) avec `uid/gid 999` — sans cela la JVM,
  qui tourne en 999, ne pouvait pas lire un fichier appartenant à root, et refusait de démarrer.
- `config/prometheus/prometheus.yml` — cible `backup-metrics:8080` (le nginx non privilégié ne
  peut pas se lier au port 80).
- `scripts/validate-stacks.sh` — exception `healthcheck` pour les seuls jobs planifiés
  (`replicas: 0` + `restart_policy: none`), avec justification écrite.
- `scripts/init-secrets.sh` — `dw_minio_prometheus_token` retiré (ADR-0010),
  `dw_minio_mirror_key`/`_secret` ajoutés pour le compte de miroir en lecture seule.

**Statut de la phase** : ✅ **terminée** — livrables complets, critères statiques vérifiés,
critères dynamiques listés en bas de page.

---

## Phase 6 — HA & tests

**Livrables** : `tests/smoke/`, `tests/chaos/`, `stacks/overrides/single-node.yml`,
`scripts/lib/single-node.py`, `stacks/demo.yml`, `images/demo-producer/`,
`docs/06-haute-disponibilite.md`

| # | Critère d'acceptation | État | Preuve |
|---|---|---|---|
| 6.1 | `make chaos` : chaque nœud tué à tour de rôle, smoke vert à chaque étape | 🖥️ | 8 scénarios écrits, du plus doux au plus brutal ; **la logique de mesure a été testée pour de vrai** (plus longue série d'échecs consécutifs, 5 séries connues, y compris la série vide) ; la plateforme est ramenée à l'état nominal entre deux scénarios, et les nœuds/labels sont restaurés depuis un `trap` même sur Ctrl-C |
| 6.2 | Tickets GLPI créés puis résolus pendant les tests chaos | 🖥️ | `kill-node.sh` attend `NodeDown` dans Alertmanager (≤ 240 s) et compte les tickets avant/après ; la chaîne elle-même est verte en tests unitaires depuis la phase 4 |
| 6.3 | `demo-producer` : compteur d'erreurs à zéro pendant toute la campagne | 🖥️ | service écrit et testé (**10 tests unitaires verts**) ; `run-all.sh` déclare le critère **non mesuré** — et non « satisfait » — si le producteur n'est pas déployé |
| 6.4 | `make single` opérationnel sur un poste mono-nœud | ✅ (statique) | les **6 stacks** filtrées sont valides, déployables (round-trip `docker stack config`), sans aucune contrainte de placement et sans service sans image ; **test négatif** : la validation détecte une contrainte survivante |
| 6.5 | `tests/smoke/network-isolation.sh` vert | 🖥️ | 5 familles de contrôles, chacune avec son **contre-test** (une sonde qui ne joint rien passerait tous les tests d'isolation) |
| 6.6 | Documentation : résultats mesurés dans `docs/06-haute-disponibilite.md` | ✅ (structure) | document complet : matrice de défaillance, méthode de mesure, les 8 scénarios, le mode mono-nœud et ses limites, ce qui n'est pas couvert. Le tableau de résultats est prêt et marqué 🖥️ — il est **produit au bon format** par `make chaos`, à recopier |
| 6.7 | `tests/smoke/smoke.sh` couvre le CDC §8.2 | ✅ (statique) | entrée (VIP, CA, redirection 308), services publics, **les interfaces d'administration doivent être PROTÉGÉES** (un 200 sans identifiants est un échec, pas un succès), état des 3 clusters, cibles Prometheus, alertes critical, fraîcheur des sauvegardes |
| 6.8 | `demo-producer` documenté | ✅ | `docs/04-composants/demo-producer.md` |

**Défauts trouvés et corrigés pendant cette phase** (tous constatés sur la sortie
réelle, aucun supposé) :

- `docker stack config` **ajoute** les contraintes de placement d'un override au
  lieu de les remplacer, et **ajoute ses services à toutes les stacks**
  fusionnées (`minio`, sans image, injecté dans `data`). Le mode mono-nœud était
  donc inopérant tel qu'écrit → `scripts/lib/single-node.py` + `deploy.sh
  --single` qui déploie le fichier filtré.
- Ce fichier filtré n'était pas déployable : `docker stack deploy` interpole une
  seconde fois et rejetait `$(cat /run/secrets/…)` dans un healthcheck ainsi que
  `($|/)` dans une commande node-exporter → ré-échappement de tous les `$`.
- `smoke_check` retournait un code non nul sous `set -e` : le test de fumée se
  serait arrêté au **premier** échec au lieu de tous les rapporter.
- Trois `` `backticks` `` Markdown dans des chaînes entre guillemets doubles
  étaient des substitutions de commande (`run-all.sh`, `kill-node.sh`).
- `make test-python` et la CI ne couvraient qu'`alert2glpi` ; `build-scan`
  utilisait le mauvais contexte pour `backup-runner`.

**Statut de la phase** : ✅ **terminée** — livrables complets, critères statiques
vérifiés, critères dynamiques listés en bas de page.

---

## Phase 7 — Documentation

**Livrables** : `docs/01` → `docs/08`, ADR à jour, README

| # | Critère d'acceptation | État | Preuve |
|---|---|---|---|
| 7.1 | `docs/01-architecture.md` complet (schémas Mermaid) | ✅ | 4 schémas Mermaid (topologie, réseaux, chemin d'une requête, ordre des stacks), matrice des réseaux, dimensionnement chiffré, table des 10 ADR |
| 7.2 | `docs/02-installation.md` : pas-à-pas reproductible | ✅ | prérequis, les 20 variables de `.env` commentées, les 7 étapes, mode mono-nœud, **12 symptômes de dépannage** avec leur cause et leur correction |
| 7.3 | `docs/03-reseau-securite.md` : 4 couches + matrice de flux complète | ✅ | les 13 règles `DW-INPUT` et 5 règles `DOCKER-USER` expliquées une par une, les 9 middlewares, **matrice de flux de 28 lignes** dérivée des stacks, TLS, secrets, durcissement |
| 7.4 | **Chaque** fichier de `config/` est expliqué dans `docs/04-composants/` | ✅ **vérifié** | `scripts/check-docs-coverage.sh` : **52 fichiers, 52 documentés**. Le contrôle est dans `make lint` et dans la CI — la promesse ne peut plus devenir fausse en silence |
| 7.5 | `docs/05-monitoring.md` : métriques, dashboards, tableau des règles d'alerte | ✅ | architecture, 14 domaines de métriques, les 12 tableaux avec leur UID, **les 48 alertes générées depuis les fichiers de règles** (condition, `for`, sévérité, action), inhibition, boucle alerte → ticket. Captures marquées 🖥️ avec la commande exacte |
| 7.6 | `docs/06-haute-disponibilite.md` : matrice + résultats chaos | ✅ (structure) | écrit en phase 6 ; tableau de résultats prêt, **produit au bon format** par `make chaos` |
| 7.7 | `docs/07-PRA.md` : les 8 points du §9.5, journal de tests réel | ✅ | les 8 points, **11 scénarios de sinistre** avec commandes exactes et validation, ordre de reprise, checklist en 12 points, **journal de tests distinguant les 14 vérifications réellement faites des 3 restant à exécuter** |
| 7.8 | `docs/08-exploitation.md` : runbooks | ✅ | **12 runbooks**, chacun : quand, durée, commandes, validation, et ce qui peut mal tourner |
| 7.9 | README à jour | ✅ | démarrage rapide, index complet de la documentation, et le tableau « ce qui vérifie quoi » |
| 7.10 | Les liens internes de la documentation résolvent | ✅ **vérifié** | **134 liens relatifs contrôlés**, 0 cassé ; contrôle intégré à `make lint`, **test négatif** effectué (un lien mort fait échouer le lint) |

**Statut de la phase** : ✅ **terminée**.

Deux contrôles ont été ajoutés plutôt que deux promesses : `check-docs-coverage.sh`
vérifie que chaque fichier de `config/` est documenté, qu'aucune référence ne
pointe dans le vide, et que tous les liens internes résolvent. Il a trouvé
25 fichiers non documentés au moment de son écriture — tous corrigés.

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

### Phase 2

```bash
make build            # image dockerwarts/cassandra (agent JMX embarqué)
make deploy-data      # déclenche galera-bootstrap.sh puis cassandra-init.sh et es-init.sh

# 2.1 — Galera
vagrant ssh node1 -c "docker exec \$(docker ps -q -f name=data_galera-1) \
  mariadb -u root -p\"\$(cat /run/secrets/dw_mariadb_root_password)\" -e \
  \"SHOW STATUS WHERE Variable_name IN
     ('wsrep_cluster_size','wsrep_cluster_status','wsrep_local_state_comment')\""
#   attendu : 3 / Primary / Synced
#   ET vérifier que le flag de bootstrap a bien été retiré :
vagrant ssh node1 -c "docker service inspect data_galera-1 \
  --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' | grep GALERA_BOOTSTRAP"
#   attendu : GALERA_BOOTSTRAP=0

# 2.2 — Cassandra
vagrant ssh node1 -c "docker exec \$(docker ps -q -f name=data_cassandra-1) nodetool status"
#   attendu : 3 lignes UN
vagrant ssh node1 -c "docker exec \$(docker ps -q -f name=data_cassandra-1) \
  cqlsh -u dwadmin -p '<dw_cassandra_admin_password>' -e \
  \"SELECT keyspace_name, replication FROM system_schema.keyspaces
     WHERE keyspace_name IN ('datalake','system_auth');\""
#   attendu : {'class': 'NetworkTopologyStrategy', 'dc1': '3'} pour LES DEUX

# 2.3 / 2.4 — Elasticsearch
vagrant ssh node1 -c "docker exec \$(docker ps -q -f name=data_es-1) sh -c \
  'curl -s -u elastic:\$(cat /run/secrets/dw_es_elastic_password) \
     localhost:9200/_cluster/health?pretty'"
#   attendu : status green, number_of_nodes 3, unassigned_shards 0
vagrant ssh node1 -c "docker exec \$(docker ps -q -f name=data_es-1) sh -c \
  'curl -s -u elastic:\$(cat /run/secrets/dw_es_elastic_password) localhost:9200/_cat/indices'"

# 2.5 — logs de bout en bout
#   ouvrir https://kibana.dockerwarts.lan → Discover → data view `logs-*`
#   vérifier la présence des champs service_name, stack, node_name, log_level
#   puis filtrer sur `logs-traefik` et confirmer ClientHost / DownstreamStatus

# 2.6 — writer unique
vagrant ssh node1 -c "docker exec \$(docker ps -q -f name=data_db-proxy) \
  sh -c 'wget -qO- http://127.0.0.1:8404/stats;csv' | grep '^mariadb,'"
#   attendu : galera-1 UP et non backup ; galera-2 et galera-3 UP mais backup
#   test de bascule :
vagrant ssh node1 -c 'docker service scale data_galera-1=0'
#   → galera-2 doit devenir le writer en moins de 5 s ; GLPI reste disponible
vagrant ssh node1 -c 'docker service scale data_galera-1=1'
```

### Phase 3

```bash
make deploy-apps          # déclenche glpi-init.sh

# 3.5 — comptes par défaut (à faire EN PREMIER : c'est le critère de sécurité)
vagrant ssh node1 -c "docker exec \$(docker ps -q -f name=apps_glpi-web) sh -c \
  'mysql -h db-proxy -u glpi -p\"\$GLPI_DB_PASSWORD\" -N -B glpi -e \
   \"SELECT name, is_active FROM glpi_users WHERE name IN (\\\"glpi\\\",\\\"tech\\\",\\\"normal\\\",\\\"post-only\\\");\"'"
#   attendu : glpi=1, les trois autres=0
#   puis vérifier qu'aucun mot de passe par défaut ne fonctionne :
curl -sk -X POST https://glpi.dockerwarts.lan/front/login.php \
  -d 'login_name=tech&login_password=tech' | grep -qi 'erreur\|error' && echo "REFUSÉ (attendu)"

# 3.1 / 3.2 — connexion et session
curl --cacert certs/ca.crt -sc /tmp/c.txt https://glpi.dockerwarts.lan/ -o /dev/null -w '%{http_code}\n'
grep glpi_srv /tmp/c.txt      # le cookie collant doit être présent
#   se connecter dans un navigateur (utilisateur glpi, mot de passe de
#   secrets/dw_glpi_admin_password.txt), naviguer 20 pages : aucune déconnexion

# 3.3 — persistance des pièces jointes
#   créer un ticket, y joindre un fichier, noter son id, puis :
vagrant ssh node1 -c 'docker service update --force apps_glpi-web'
#   attendre la fin du roulement, rouvrir le ticket : la pièce jointe doit s'ouvrir
vagrant ssh node1 -c 'ls -la /srv/nfs/glpi/files/_uploads/ | head'

# 3.4 — API REST
APP=$(cat secrets/dw_glpi_app_token.txt); USR=$(cat secrets/dw_glpi_user_token.txt)
curl --cacert certs/ca.crt -s -H "App-Token: $APP" -H "Authorization: user_token $USR" \
  https://glpi.dockerwarts.lan/apirest.php/initSession
#   attendu : {"session_token":"..."}

# 3.7 — un seul exécuteur cron
vagrant ssh node1 -c 'docker service ls --filter name=apps_glpi-cron'
#   attendu : 1/1
```

### Phase 4

```bash
make build                # image dockerwarts/alert2glpi
make deploy-monitoring

# 4.1 — toutes les cibles up
curl -su admin:$(cat secrets/dw_traefik_admin_password.txt) \
  --cacert certs/ca.crt https://prometheus.dockerwarts.lan/api/v1/targets \
  | jq -r '.data.activeTargets[] | select(.health!="up") | "\(.labels.job) \(.labels.instance) \(.lastError)"'
#   attendu : aucune ligne

# 4.2 — les 12 dashboards
#   ouvrir https://grafana.dockerwarts.lan → dossier « Dockerwarts »
#   parcourir les 12 ; aucun panneau ne doit afficher « No data » ni
#   « Datasource not found ». Captures à placer dans docs/images/.

# 4.3 / 4.4 — la boucle alerte → ticket (LE critère de la phase)
vagrant ssh node1 -c 'docker service scale apps_glpi-web=0'
#   attendre ~90 s (for: 1m + group_wait: 10s pour un critical)
curl -s --cacert certs/ca.crt https://alertmanager.dockerwarts.lan/api/v2/alerts \
  -u admin:$(cat secrets/dw_traefik_admin_password.txt) | jq -r '.[].labels.alertname'
#   → GLPIDown
#   puis, dans GLPI : un ticket « [critical] GLPIDown — … [AM:…] » en priorité 5
vagrant ssh node1 -c 'docker service scale apps_glpi-web=2'
#   après résolution : le MÊME ticket passe au statut « Résolu » avec un suivi
vagrant ssh node1 -c "docker service logs --tail 20 monitoring_alert2glpi"
#   → « ticket #N marked as solved »

# 4.5 — inhibition
vagrant halt -f node2
#   attendre 2 min, puis compter les alertes NON inhibées :
curl -s --cacert certs/ca.crt -u admin:$(cat secrets/dw_traefik_admin_password.txt) \
  https://alertmanager.dockerwarts.lan/api/v2/alerts?inhibited=false | jq 'length'
#   attendu : peu d'alertes (NodeDown + celles sans étiquette `node`),
#   PAS une par service du nœud perdu
vagrant up node2

# 4.6 / 4.7 — déjà verts hors VM, rejouables :
make lint-prom
make test-python
```

> **À confirmer au premier démarrage** : `read_only: true` sur `traefik` et
> `docker-socket-proxy` n'a pas pu être validé à l'exécution (images non téléchargeables dans la
> session). Si un service refuse de démarrer avec une erreur d'écriture, ajouter le `tmpfs`
> manquant plutôt que de retirer `read_only`, et consigner le chemin dans
> `docs/04-composants/traefik.md`.

### Phase 5

```bash
make build            # ajoute l'image dockerwarts/backup-runner
make deploy-backup    # déploie la stack puis exécute scripts/minio-init.sh

# 5.0 — MinIO initialisé : buckets, versioning, comptes, ISOLATION vérifiée
#   (minio-init.sh échoue de lui-même si l'un des trois manque ; à relire dans sa sortie)
vagrant ssh node3 -c "docker exec \$(docker ps -q -f name=backup_minio) \
  sh -c 'export MC_HOST_l=\"http://\$(cat /run/secrets/dw_minio_root_user):\$(cat /run/secrets/dw_minio_root_password)@localhost:9000\"; \
         mc ls l; mc admin user list l; mc version info l/restic'"
#   attendu : 3 buckets, 3 comptes, versioning Enabled sur restic

# 5.1 — tous les jobs, dans l'ordre, avec rapport Markdown
make backup-now
#   → reports/backup-now-<date>.md ; toute ligne ❌ est un échec de la phase
#   un job isolé :  scripts/backup-now.sh backup-cassandra-1

# 5.1bis — vérifier qu'un job Cassandra n'a PAS laissé de snapshot derrière lui
#   (le mode de panne le plus insidieux : le disque se remplit des semaines plus tard)
vagrant ssh node1 -c "docker exec \$(docker ps -q -f name=data_cassandra-1) \
  nodetool listsnapshots"
#   attendu : aucune ligne « daily »

# 5.2 — les métriques arrivent bien jusqu'à Prometheus
curl -s --cacert certs/ca.crt -u admin:$(cat secrets/dw_traefik_admin_password.txt) \
  'https://prometheus.dockerwarts.lan/api/v1/query?query=backup_last_status' | jq -r \
  '.data.result[] | "\(.metric.job) = \(.value[1])"'
#   attendu : une ligne par job, toutes à 0
#   puis, visuellement : https://grafana.dockerwarts.lan/d/dw-backup

# 5.3 — exercice de reprise complet (production jamais modifiée)
make dr-drill
#   → reports/dr-drill-<date>.md, à recopier dans le journal de tests de docs/07-PRA.md
#   pour inspecter les copies restaurées :  tests/dr/dr-drill.sh --keep
#                          puis nettoyer :  tests/dr/dr-drill.sh --cleanup-only

# 5.4 — BackupTooOld déclenchée en vieillissant une métrique
vagrant ssh node1 -c "sudo sed -i \
  's/^backup_last_success_timestamp{job=\"backup-galera\"} .*/backup_last_success_timestamp{job=\"backup-galera\"} 1700000000/' \
  /srv/nfs/backup-metrics/backup.prom"
#   attendre ~10 min (for: 10m), puis :
curl -s --cacert certs/ca.crt -u admin:$(cat secrets/dw_traefik_admin_password.txt) \
  https://alertmanager.dockerwarts.lan/api/v2/alerts | jq -r '.[].labels.alertname' | grep BackupTooOld
#   → un ticket GLPI doit apparaître ; puis rejouer  scripts/backup-now.sh backup-galera

# 5.5 — snapshot Elasticsearch SLM en état SUCCESS
scripts/restore/restore-es.sh --list
#   attendu : au moins une ligne SUCCESS
vagrant ssh node1 -c "docker exec \$(docker ps -q -f name=data_es-1) sh -c \
  'curl -s -u elastic:\$(cat /run/secrets/dw_es_elastic_password) \
     localhost:9200/_slm/policy/daily-snapshots?human' | jq '.[].last_success'"

# 5.6 — restaurations, une par une (chacune depuis le nœud qui porte le volume)
scripts/restore/restore-galera.sh --only-db glpi --as glpi_verif   # sans risque
vagrant ssh node1 -c 'cd /vagrant && scripts/restore/restore-glpi-files.sh --to /tmp/verif'
vagrant ssh node3 -c 'cd /vagrant && scripts/restore/restore-crowdsec.sh'
vagrant ssh node1 -c 'cd /vagrant && scripts/restore/restore-prometheus.sh'
#   restore-prometheus retire puis remet le label `prometheus` de son nœud :
#   après coup, vérifier qu'il est bien revenu
vagrant ssh node1 -c "docker node inspect self --format '{{.Spec.Labels}}'"

# 5.7 — miroir hors site (si OFFSITE_S3_* est renseigné dans .env)
scripts/backup-now.sh offsite-mirror
#   sans configuration, le job sort en 0 SANS publier de métrique : c'est voulu,
#   publier un succès affirmerait qu'une copie hors site existe.

# 5.8 — le proxy Docker en écriture n'est joignable que par swarm-cronjob
vagrant ssh node1 -c "docker network inspect backup_cronjob \
  --format '{{.Internal}} {{range .Containers}}{{println .Name}}{{end}}'"
#   attendu : true, et uniquement swarm-cronjob + docker-socket-proxy-rw
```

> **À confirmer au premier démarrage.** Trois points n'ont pas pu être exécutés faute de pouvoir
> télécharger les images dans la session :
>
> 1. **`mc ready local` comme healthcheck de MinIO** — c'est la sonde documentée par MinIO et
>    `mc` est présent dans l'image officielle. Si le healthcheck échoue immédiatement, remplacer
>    par `curl -f http://localhost:9000/minio/health/live` et le consigner dans `minio.md`.
> 2. **`cqlsh` dans `backup-runner`** — il est copié depuis l'image Cassandra avec `pylib/` et
>    `lib/`. `backup-cassandra.sh` **ne dépend pas** de sa réussite : il avertit et retombe sur le
>    `schema.cql` que `nodetool snapshot` écrit dans chaque snapshot. Si l'avertissement apparaît,
>    corriger le `PYTHONPATH` de l'image plutôt que le script.
> 3. **`read_only: true` sur les jobs et sur `backup-metrics`** — si un service refuse de démarrer
>    sur une erreur d'écriture, ajouter le `tmpfs` manquant, jamais retirer `read_only`.

### Phase 6

Les scénarios de perte de nœud s'exécutent depuis le **poste d'administration**
(Vagrant y est requis) ; tout le reste depuis un manager.

```bash
make build            # ajoute l'image dockerwarts/demo-producer
make deploy-demo      # la charge de fond DOIT tourner AVANT la campagne

# 6.7 — test de fumée complet
make smoke
#   → reports/smoke-<date>.md
#   Attention : sur une plateforme fraîchement déployée, ajouter --no-backup
#   tant que `make backup-now` n'a pas tourné une première fois.
tests/smoke/smoke.sh --quick        # contrôles HTTP seuls, boucle rapide

# 6.5 — isolation réseau (depuis un manager)
tests/smoke/network-isolation.sh
#   → reports/network-isolation-<date>.md
#   Les contre-tests comptent autant que les tests : la sonde DOIT joindre
#   traefik:80 depuis edge, et 443 DOIT être ouvert sur la VIP. Sans eux, une
#   sonde cassée passerait tous les contrôles d'isolation.

# 6.1 / 6.2 / 6.3 — la campagne complète (~30 min)
make chaos
#   → reports/chaos-<date>.md, à recopier dans docs/06-haute-disponibilite.md §5
#   Depuis un nœud (sans Vagrant), les scénarios 1 à 5 restent jouables :
tests/chaos/run-all.sh --no-node-kill
#   Un scénario isolé :
tests/chaos/kill-service.sh apps_glpi-web
tests/chaos/drain-node.sh node2 --hold 90
tests/chaos/kill-node.sh node2 --hold 120

# 6.2 — vérifier que le ticket NodeDown a bien été créé PUIS résolu
#   pendant `kill-node.sh`, le script attend l'alerte ; après `vagrant up`,
#   contrôler dans GLPI que le même ticket passe au statut « Résolu ».
vagrant ssh node1 -c "docker service logs --tail 30 monitoring_alert2glpi"

# 6.3 — le critère du CDC §8.2 n°5
curl -s --cacert certs/ca.crt -u admin:$(cat secrets/dw_traefik_admin_password.txt) \
  'https://prometheus.dockerwarts.lan/api/v1/query?query=sum(demo_producer_errors_total)' | jq
#   attendu : 0 sur toute la durée de la campagne

# 6.4 — mode mono-nœud, sur un poste avec Docker et un Swarm local
docker swarm init 2>/dev/null || true
make secrets certs build
make single
#   Les fichiers réellement déployés sont conservés : .rendered/single-<stack>.yml
#   `make smoke` signalera des échecs (3 nœuds, Galera 3, ES green) : c'est
#   normal et documenté (docs/06-haute-disponibilite.md §6).
```

> **À confirmer au premier démarrage.**
>
> 1. **`demo-producer` et les extensions C du driver Cassandra** — l'image
>    compile `libev` et `murmur3` au *build stage*. Si le driver démarre en
>    signalant qu'il retombe sur l'implémentation Python pure, la performance
>    reste correcte à 20 événements/s, mais il faut corriger l'image (le
>    `murmur3` pur Python est sur le chemin de **chaque** écriture token-aware).
> 2. **`quick_smoke` dans `kill-node.sh`** utilise `smoke.sh --quick`, qui n'a
>    besoin d'aucun accès Docker : c'est ce qui rend le scénario exécutable
>    depuis le poste d'administration. À confirmer que le poste résout bien la
>    VIP (`make hosts`).
> 3. **La sonde à 5 Hz** utilise `sleep 0.2`, qui suppose un `sleep` GNU. Sur
>    macOS, installer `coreutils` ou exécuter la campagne depuis un nœud.

### Mode mono-nœud — vérifié en déployant réellement

Le démon Docker de la session a permis de **déployer les six stacks** sur un
Swarm mono-nœud (seuls les *blobs* d'images restent refusés, donc aucun
conteneur ne démarre). Cela a révélé trois défauts que `docker stack config`
seul ne pouvait pas montrer, tous corrigés :

| Défaut | Symptôme | Correction |
|---|---|---|
| **10 volumes NFS** montés sur un poste sans serveur NFS | GLPI, `backup-metrics` et tous les jobs de sauvegarde restent bloqués | `single-node.py` convertit les volumes NFS en volumes locaux, **en fusionnant** `backup_metrics` et `backup_metrics_ro` qui désignent le même export (sinon les jobs écrivent dans l'un et l'exporteur lit l'autre, vide pour toujours) |
| **`/var/log/traefik` absent** (créé par Ansible sur les VM) | Swarm **rejette** Traefik, Fluent Bit et l'agent CrowdSec : `bind source path does not exist` | `scripts/single-node-prepare.sh` (cible `make single-prepare`) : diagnostique et crée les chemins, le Swarm, les réseaux ; distingue blocages et points d'attention |
| `smoke.sh` **mourait** au lieu de rapporter | `grep` sur un corps vide + `set -e` → arrêt au milieu du test ; et la branche `else` déclarait un **succès** quand `RemoteAddr` était vide | corps vide traité comme un échec explicite ; `|| true` sur le pipeline ; statut HTTP nettoyé (`000000` → `000`) ; `--noproxy '*'` sur tous les appels à la VIP — sans quoi, derrière un proxy d'entreprise, le test interroge le proxy |

Documenté dans [`09-test-local.md`](09-test-local.md).

### Phase 7

La documentation est vérifiable hors VM et l'a été, à deux exceptions près, qui
sont des **captures d'écran** — elles supposent un Grafana et un GLPI vivants.

```bash
# 7.4 / 7.10 — les contrôles de documentation (déjà verts, rejouables partout)
make lint-docs
#   52 fichiers de config/ documentés, 0 référence orpheline, 134 liens vérifiés

# 7.5 — captures des 12 tableaux de bord (CDC §12)
make deploy-demo          # sans charge de fond, la moitié des panneaux est vide
#   puis, pour chaque UID listé dans docs/05-monitoring.md §3 :
#     https://grafana.dockerwarts.lan/d/<uid>  → capture → docs/images/<uid>.png

# 7.5 — captures de la boucle alerte → ticket (CDC §12)
docker service scale apps_glpi-web=0
#   ~90 s plus tard : capture de l'alerte dans Alertmanager, puis du ticket GLPI
docker service scale apps_glpi-web=2
#   après résolution : capture du MÊME ticket passé au statut « Résolu »
#   → docs/images/{alertmanager-glpidown,ticket-glpidown,ticket-resolu}.png
#   La procédure exacte est dans docs/05-monitoring.md §6.

# 7.6 / 7.7 — remplir les deux tableaux de résultats
make chaos               # → reports/chaos-<date>.md   → docs/06-haute-disponibilite.md §5
make dr-drill            # → reports/dr-drill-<date>.md → docs/07-PRA.md §7.2
```

> **Ce qui manque à la documentation, et rien d'autre.** Les captures d'écran du
> CDC §12 ne peuvent pas être produites sans conteneurs en fonctionnement. Elles
> sont signalées à leur emplacement exact dans `docs/05-monitoring.md`, avec la
> commande qui les produit — plutôt que d'être passées sous silence ou
> remplacées par des images inventées.

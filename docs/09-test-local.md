# Tester le projet en local, sur une machine avec Docker

> **Objet** : faire tourner et éprouver la plateforme sur **un seul poste**, sans
> VirtualBox ni Vagrant.
> **À lire d'abord si vous voulez la vraie topologie** (3 VM, HA, VIP) :
> [`02-installation.md`](02-installation.md).
>
> Ce mode s'appelle **mono-nœud** (CDC §3.2). Il déploie **exactement les mêmes
> définitions** que la production — mêmes images, mêmes configurations, mêmes
> secrets, mêmes scripts d'initialisation — sur un Swarm à un nœud.

---

## 0. En dix secondes

```bash
git clone <dépôt> dockerwarts && cd dockerwarts
cp .env.example .env && $EDITOR .env      # §2 : 4 lignes à changer
make single-prepare ARGS=--fix            # §3 : prépare le poste (demande sudo)
make secrets certs                        # §4
make build                                # §5
make single                               # §6 : déploie les 6 stacks
make hosts | sudo tee -a /etc/hosts       # §7 : accéder au navigateur
```

Puis `https://glpi.dockerwarts.lan` et `https://grafana.dockerwarts.lan`.

Le reste de ce document explique chaque étape, **ce qui ne marchera pas dans ce
mode** (§8, à lire), et comment tester sans rien déployer du tout (§1).

---

## 1. Le niveau zéro : tester sans Docker

Une bonne partie du projet se vérifie **sans démarrer un seul conteneur**, en
moins d'une minute. C'est le premier réflexe, et c'est ce que fait la CI.

```bash
make lint          # yamllint, shellcheck, hadolint, ruff, promtool, amtool,
                   # docker stack config, couverture de la documentation
make test-python   # 32 tests unitaires (alert2glpi, demo-producer)
```

| Ce que ça vérifie | Comment |
|---|---|
| Les 6 stacks sont valides et déployables | `docker stack config` (aucun démon requis) |
| Aucun service sans durcissement, limites, journalisation | contrôle Python dans `validate-stacks.sh` |
| Toute image est épinglée tag **et** digest | idem |
| Les 48 règles d'alerte se déclenchent quand il faut | 15 tests `promtool test rules` |
| Les 12 tableaux de bord sont cohérents | `check-grafana.py` : 155 panneaux, 0 orphelin |
| Aucun secret dans git | `check-no-secrets.sh` |
| Chaque fichier de `config/` est documenté | `check-docs-coverage.sh` |

> `make lint-ansible` échoue si les collections Galaxy ne sont pas installées :
> `ansible-galaxy collection install -r ansible/requirements.yml` d'abord.
> Les autres cibles de lint n'ont besoin de rien.

---

## 2. Prérequis et `.env`

### Ce qu'il faut

| | Minimum | Confortable |
|---|---|---|
| Docker Engine | 24+, **en mode Swarm** | 29 |
| RAM libre | 8 Gio (avec `PROFILE=light`) | 16 Gio |
| Disque | 20 Gio | 40 Gio |
| Ports **80** et **443** | libres | libres |

Docker Desktop (macOS, Windows) fonctionne, avec deux limites signalées au §8.
Sous Linux, tout fonctionne.

### Les quatre lignes de `.env` à changer

```bash
cp .env.example .env
```

| Variable | Valeur en local | Pourquoi |
|---|---|---|
| `VIP` | `127.0.0.1` | Keepalived n'existe pas ici : Traefik prend les ports de **votre** machine. `make smoke` et les tests interrogent `$VIP` |
| `REGISTRY` | `127.0.0.1:5000` | Docker traite `127.0.0.1` et `localhost` comme des registres non sécurisés **sans configuration** ; toute autre adresse imposerait de modifier `daemon.json` |
| `ADMIN_CIDR` | `0.0.0.0/0` sur un poste isolé | c'est la liste blanche des interfaces d'administration. Depuis un conteneur ou un navigateur local, l'IP source n'est pas celle des VM : sans ça, **tout renvoie 403**, y compris pour vous |
| `PROFILE` | `light` si moins de 12 Gio | réduit les *heaps* JVM de Cassandra et Elasticsearch |

```bash
sed -i 's|^VIP=.*|VIP=127.0.0.1|;         s|^REGISTRY=.*|REGISTRY=127.0.0.1:5000|; \
        s|^ADMIN_CIDR=.*|ADMIN_CIDR=0.0.0.0/0|; s|^PROFILE=.*|PROFILE=light|' .env
```

> **`ADMIN_CIDR=0.0.0.0/0` ouvre les interfaces d'administration à qui peut
> joindre la machine.** C'est acceptable sur un poste de développement isolé, et
> **seulement** là. Sur un réseau partagé, mettez l'adresse de votre poste.

`NFS_SERVER` peut rester tel quel : en mono-nœud les volumes NFS sont convertis
en volumes locaux (§8.1), la valeur n'est plus lue.

---

## 3. Préparer le poste — `make single-prepare`

C'est l'étape que l'on saute et qu'on regrette. Sur les VM, Ansible prépare
l'hôte ; `make single` saute Ansible — c'est son intérêt — et hérite donc d'un
poste **non préparé**. Swarm accepte alors les stacks, puis **rejette les
tâches** une par une avec des messages qui ne disent pas quoi faire :

```
"invalid mount config for type bind: bind source path does not exist: /var/log/traefik"
```

```bash
make single-prepare              # diagnostique, ne modifie rien
make single-prepare ARGS=--fix   # crée ce qui peut l'être (demande sudo)
```

Ce qu'il contrôle :

| # | Contrôle | Ce qu'il corrige avec `--fix` |
|---|---|---|
| 1 | démon Docker et mode Swarm | `docker swarm init` |
| 2 | chemins hôte bind-montés | crée `/var/log/traefik`, `/var/log/auth.log`, `/var/log/kern.log` |
| 3 | les 5 réseaux overlay | les crée (`internal` sauf `edge`) |
| 4 | ports 80 et 443 libres | signale seulement — à vous d'arrêter ce qui les occupe |
| 5 | mémoire disponible vs `PROFILE` | signale seulement |
| 6 | `.env` adapté au local (§2) | signale seulement |

Il distingue les **blocages** (✘, le déploiement échouera) des **points
d'attention** (⚠, un service ne démarrera pas sans conséquence pour le reste).

---

## 4. Secrets et certificats

```bash
make secrets    # 41 secrets, générés localement puis créés dans Swarm
make certs      # CA interne + certificat wildcard *.dockerwarts.lan
```

Tout reste sur votre machine, dans `secrets/` et `certs/` (tous deux dans
`.gitignore`). Rien à mettre dans un coffre pour un test local — mais si vous
comptez tester une restauration (§7.3), ne supprimez pas `secrets/` entre-temps :
sans `dw_restic_password`, le dépôt de sauvegarde est illisible.

---

## 5. Construire les images maison

```bash
make build      # déploie d'abord le registre interne, puis construit et pousse
```

Quatre images : `cassandra` (agent JMX embarqué), `alert2glpi`, `backup-runner`,
`demo-producer`. Comptez 5 à 10 minutes la première fois.

> **`make build` refuse d'écraser un tag existant.** Après avoir modifié une
> image, incrémentez `IMAGE_TAG` dans `.env` (ou passez `--force`). C'est ce qui
> évite la situation où l'on redéploie en croyant avoir mis à jour.

---

## 6. Déployer

```bash
make single
```

Les six stacks, dans l'ordre, avec les initialisations au bon moment :
`edge` → `data` (+ bootstrap Galera, `cassandra-init`, `es-init`) → `apps`
(+ `glpi-init`) → `monitoring` → `backup` (+ `minio-init`).

Comptez **10 à 15 minutes** : Cassandra et Elasticsearch démarrent lentement
(`start_period` de 240 s sur Cassandra), et c'est normal.

```bash
make status                       # services, nœuds, santé des clusters
docker service ls                 # ce qui tourne
docker service ps <svc> --no-trunc   # POURQUOI une tâche ne démarre pas
```

Le fichier réellement déployé est conservé : `.rendered/single-<stack>.yml`.
C'est là qu'il faut regarder si un service se comporte bizarrement dans ce mode.

---

## 7. Ce qu'on peut tester, et comment

### 7.1 Accéder aux interfaces

```bash
make hosts | sudo tee -a /etc/hosts
```

Avec `VIP=127.0.0.1`, cela ajoute les huit noms pointant vers votre machine.

| URL | Identifiants |
|---|---|
| `https://glpi.dockerwarts.lan` | `glpi` / `secrets/dw_glpi_admin_password.txt` |
| `https://grafana.dockerwarts.lan` | `admin` / `secrets/dw_grafana_admin_password.txt` |
| `https://prometheus.dockerwarts.lan` | `admin` / `secrets/dw_traefik_admin_password.txt` |
| `https://alertmanager.dockerwarts.lan` | idem |
| `https://kibana.dockerwarts.lan` | `elastic` / `secrets/dw_es_elastic_password.txt` |
| `https://minio.dockerwarts.lan` | `secrets/dw_minio_root_{user,password}.txt` |
| `https://traefik.dockerwarts.lan` | `admin` / `secrets/dw_traefik_admin_password.txt` |
| `https://whoami.dockerwarts.lan` | public — le plus simple pour vérifier que ça marche |

Le certificat est signé par la CA interne : importez `certs/ca.crt` dans le
navigateur, ou acceptez l'avertissement.

### 7.2 Le test de fumée

```bash
make smoke ARGS=--no-backup      # --no-backup tant qu'aucune sauvegarde n'a tourné
```

Il passe par `$VIP` en HTTPS avec la CA interne : il éprouve Traefik, le
certificat, les routeurs et les middlewares, puis l'état des clusters et la
supervision. Il produit un rapport dans `reports/`.

> **Il signalera des échecs, et il a raison.** En mono-nœud il attend 3 nœuds
> Swarm, `wsrep_cluster_size = 3` et Elasticsearch `green` — des propriétés de la
> topologie de production. Ce qui doit passer en local :
>
> | Contrôle | Attendu en local |
> |---|---|
> | VIP joignable, certificat validé, redirection 308 | ✅ |
> | whoami, GLPI `status.php` = `GLPI_OK` | ✅ |
> | Interfaces d'administration protégées (401/403 sans identifiants) | ✅ |
> | Nœuds Swarm = 3, managers = 3 | ❌ attendu (il y en a 1) |
> | `wsrep_cluster_size` = 3 | ❌ attendu (1) |
> | Cassandra 3 UN | ❌ attendu (1) |
> | Elasticsearch `green` | ❌ attendu (`yellow`, voir §8.2) |

Pour ne garder que la partie pertinente en local :

```bash
tests/smoke/smoke.sh --quick     # contrôles HTTP seuls : tout doit être vert
```

### 7.3 Sauvegardes et restauration

C'est la partie la plus intéressante à éprouver en local, et **elle fonctionne
entièrement** :

```bash
make backup-now                  # tous les jobs, immédiatement, avec rapport
cat reports/backup-now-*.md

scripts/restore/restore-all.sh --list      # ce que contient le dépôt

make dr-drill                    # exercice de reprise : restaure POUR DE VRAI
cat reports/dr-drill-*.md        # à côté de la production, compare, nettoie
```

`make dr-drill` restaure Galera dans `glpi_restore`, Elasticsearch en
`restored-*`, Cassandra dans `datalake_restore` et les fichiers GLPI dans un
répertoire temporaire, compare chaque résultat avec la production, puis nettoie
depuis un `trap`. **La production n'est jamais modifiée.**

Deux jobs échoueront, et c'est correct : `backup-cassandra-2` et `-3` ne
trouvent pas de membre à sauvegarder puisqu'ils ne tournent pas (§8.2). Mieux
vaut un échec visible qu'une archive vide déclarée en succès.

### 7.4 La boucle alerte → ticket GLPI

La démonstration la plus parlante du projet, et elle marche en local :

```bash
docker service scale apps_glpi-web=0
#   ~90 s plus tard (for: 1m + group_wait: 10s), l'alerte est active :
curl -sk https://alertmanager.dockerwarts.lan/api/v2/alerts \
  -u admin:$(cat secrets/dw_traefik_admin_password.txt) | jq -r '.[].labels.alertname'
#   → GLPIDown
#   … et dans GLPI : un ticket « [critical] GLPIDown — … [AM:…] », priorité 5

docker service scale apps_glpi-web=1
#   le MÊME ticket passe au statut « Résolu », avec un suivi :
docker service logs --tail 20 monitoring_alert2glpi
```

### 7.5 Le datalake et les tableaux de bord

```bash
make deploy-demo     # charge de fond : ~20 événements/s vers Cassandra et ES
```

Sans lui, la moitié des panneaux Grafana sont vides — un tableau de bord de
datalake sans données ne prouve rien. Puis :
`https://grafana.dockerwarts.lan/d/dw-datalake`.

### 7.6 L'isolation réseau

```bash
tests/smoke/network-isolation.sh
```

Vérifie sur le cluster **vivant** qu'un conteneur du réseau `edge` ne joint pas
`galera-1:3306`, qu'aucun port de base ne répond sur l'hôte, que seuls les deux
proxies voient le socket Docker, et que le proxy en lecture seule refuse un
`POST`. Chaque famille a son **contre-test**.

> Un contrôle échouera en local : « aucun port de données ouvert sur
> `192.168.56.11/12/13` » — ces adresses n'existent pas ici. Les contrôles
> depuis `edge`, eux, sont pleinement valables.

### 7.7 Les tests chaos

```bash
make chaos ARGS=--no-node-kill
```

Les scénarios 1 à 5 (perte d'une tâche, mise à jour glissante, drain) sont
jouables : Swarm replanifie sur le seul nœud disponible. Les scénarios 6 à 8
(`vagrant halt`) ne le sont pas — il n'y a pas de nœud à éteindre.

L'indisponibilité mesurée en mono-nœud sera **plus élevée** qu'en production :
avec un seul replica, tuer une tâche coupe réellement le service le temps du
redémarrage. C'est la démonstration, en creux, de ce que la HA apporte.

---

## 8. Ce qui diffère de la production — à lire

Le mode mono-nœud n'est **pas** une petite production. Ce qui change, et
pourquoi :

### 8.1 Ce que le filtre mono-nœud modifie

`scripts/lib/single-node.py` transforme la stack fusionnée avant déploiement.
Quatre transformations, chacune pour une raison constatée :

| Transformation | Pourquoi |
|---|---|
| Contraintes de placement supprimées | `docker stack config` **ajoute** les contraintes d'un override au lieu de les remplacer : sans ce filtre, chaque service resterait `Pending` pour toujours |
| Services sans image supprimés | un fichier d'override ajoute ses services à **toutes** les stacks fusionnées : `minio` (sans image) serait injecté dans `data` |
| `$` ré-échappés en `$$` | `docker stack deploy` interpole une seconde fois et rejetterait `$(cat /run/secrets/…)` dans un healthcheck |
| **Volumes NFS → volumes locaux** | sur un poste sans serveur NFS, dix volumes ne se montent pas et GLPI, l'exporteur de métriques et tous les jobs de sauvegarde restent bloqués |

Sur la dernière : `backup_metrics` (écriture, pour les jobs) et
`backup_metrics_ro` (lecture seule, pour l'nginx) désignent le **même** export.
Le filtre les fusionne en un seul volume local — sans quoi les jobs
écriraient dans l'un et l'exporteur lirait l'autre, vide pour toujours et sans
message d'erreur.

### 8.2 Ce qui n'est pas testé dans ce mode

| Composant | En local | Conséquence |
|---|---|---|
| **Galera** | 1 nœud, pas de quorum ni de réplication synchrone | `innodb_flush_log_at_trx_commit=0` — sûr en production *parce que* l'écriture est déjà sur deux autres machines — redevient un vrai risque en cas de crash. L'inversion est gérée dans `config/galera/entrypoint.sh` |
| **Cassandra** | RF=1 | perdre le volume, c'est perdre les données. `LOCAL_QUORUM` = 1 réplica |
| **Elasticsearch** | 1 nœud, **`yellow` pour toujours** | un shard replica ne peut pas être alloué sur le nœud qui porte le primaire. `yellow` est l'état **correct** ici, pas un problème |
| **Keepalived / VIP** | inexistants | Traefik prend les ports de la machine ; pas de bascule à mesurer |
| **Prometheus** | 1 instance | la HA par duplication n'a pas de sens sur un nœud |
| **Alertmanager** | 1 membre | il forme un cluster à un membre et déduplique normalement |
| **`backup-cassandra-2/3`** | échouent | pas de membre 2 ni 3 à sauvegarder — échec **visible**, plutôt qu'une archive vide en succès |
| **Chiffrement IPsec du réseau `data`** | omis | il protégerait un trafic qui ne quitte pas la machine |

### 8.3 Limites propres à Docker Desktop (macOS, Windows)

| Symptôme | Cause | Conséquence |
|---|---|---|
| `cadvisor` rejeté | `/dev/disk` n'existe pas dans la VM de Docker Desktop | panneaux « conteneurs » vides ; le reste de la supervision fonctionne |
| `crowdsec-agent` sans source système | pas de `/var/log/auth.log` ni `/var/log/kern.log` | CrowdSec perd 1 source sur 3 ; Traefik et les conteneurs suffisent pour la démonstration |
| `node-exporter` partiel | il mesure la VM Docker, pas votre Mac | les métriques hôte décrivent la VM |

Aucune n'empêche de tester GLPI, le monitoring, les sauvegardes ou la boucle
alerte → ticket.

---

## 9. Dépannage

| Symptôme | Cause | Correction |
|---|---|---|
| `bind source path does not exist: /var/log/traefik` | poste non préparé | `make single-prepare ARGS=--fix` |
| Un service reste `0/1` | image absente, port pris, ou mémoire | `docker service ps <svc> --no-trunc` — l'erreur y est en clair |
| Tout renvoie **403** | `ADMIN_CIDR` ne couvre pas votre source | §2, puis `make deploy-edge` |
| Tout renvoie **403** brutalement, après des essais | CrowdSec vous a banni | `docker exec $(docker ps -q -f name=edge_crowdsec-lapi) cscli decisions delete --all` |
| `network edge not found` | réseaux overlay absents | `make single-prepare ARGS=--fix` |
| `image not found` au déploiement | `make build` non fait, ou `IMAGE_TAG` incohérent | `curl http://127.0.0.1:5000/v2/_catalog` |
| Elasticsearch ne démarre pas | `vm.max_map_count` trop bas (posé par Ansible sur les VM) | Linux : `sudo sysctl -w vm.max_map_count=262144`. Docker Desktop : le faire dans la VM |
| Cassandra tué par l'OOM | mémoire insuffisante | `PROFILE=light` dans `.env`, puis `make deploy-data` |
| `make smoke` rouge sur les clusters | attendu en mono-nœud | §7.2 — utiliser `--quick` |
| Une configuration modifiée n'a aucun effet | objet config Swarm immuable | le hash de contenu roule le service : redéployer la stack suffit |

**Repartir de zéro :**

```bash
for s in demo backup monitoring apps data edge registry; do docker stack rm $s; done
sleep 20                      # laisser Swarm libérer les réseaux
docker volume prune -f        # ⚠️ efface les données
docker secret ls -q | xargs -r docker secret rm
make single-prepare ARGS=--fix && make secrets certs build single
```

---

## 10. Ce qu'un test local prouve, et ce qu'il ne prouve pas

**Prouve** : que les stacks se déploient, que les initialisations
fonctionnent, que GLPI parle à sa base, que la supervision découvre ses cibles,
que les alertes remontent en tickets, que les sauvegardes s'exécutent **et se
restaurent**, et que la segmentation réseau tient.

**Ne prouve pas** : la haute disponibilité. Le quorum, la bascule de VIP, la
resynchronisation d'un nœud, la survie à la perte d'une machine — tout cela est
une propriété d'avoir trois nœuds, et ne peut s'observer que sur les trois VM
([`02-installation.md`](02-installation.md), puis
[`06-haute-disponibilite.md`](06-haute-disponibilite.md)).

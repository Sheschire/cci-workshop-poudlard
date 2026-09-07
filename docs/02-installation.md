# Installation

> **Objet** : monter la plateforme de zéro, sur trois VM ou sur un poste unique.
> **Références** : CDC §3, §11.1 ; [ADR-0002](adr/0002-vagrant-ansible.md).
> Pour comprendre ce qui est monté : [`01-architecture.md`](01-architecture.md).

---

## 1. Prérequis

Sur le **poste d'administration** (la machine depuis laquelle vous pilotez) :

| Outil | Version minimale | Vérifier |
|---|---|---|
| VirtualBox | 7.0 | `VBoxManage --version` |
| Vagrant | 2.4 | `vagrant --version` |
| Ansible | 2.16 (ansible-core) | `ansible --version` |
| make, git, curl, openssl | — | `make -v && git --version` |
| python3 | 3.10 | `python3 --version` |

Matériel : **20 Gio de RAM libres** et 4 cœurs pour le profil `full`
(3 × 6 Gio + le poste). Avec moins, voir le profil `light` au §3.

Les nœuds n'ont besoin de rien : Vagrant fabrique les VM, Ansible installe tout
le reste (Docker, pare-feu, NFS, Keepalived, Swarm, réseaux, labels).

```bash
git clone <url-du-dépôt> dockerwarts && cd dockerwarts
ansible-galaxy collection install -r ansible/requirements.yml
```

## 2. Le tour rapide

Six commandes, dans cet ordre. Chacune est détaillée ensuite.

```bash
cp .env.example .env                                   # 1. paramètres
cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml
make vms provision                                     # 2. VM + hôtes + Swarm  (~15 min)
make secrets certs                                     # 3. secrets et certificats
make build                                             # 4. images maison
make deploy                                            # 5. les 5 stacks, dans l'ordre  (~10 min)
make smoke ARGS=--no-backup                                 # 6. validation
make hosts | sudo tee -a /etc/hosts                    # 7. accéder depuis le navigateur
```

`make help` liste toutes les cibles.

## 3. Étape 1 — `.env`

Le fichier `.env` n'est **jamais** commité (il est dans `.gitignore`), et
`.env.example` en est le modèle à jour.

| Variable | Défaut | À changer si… |
|---|---|---|
| `DOMAIN` | `dockerwarts.lan` | vous avez un vrai domaine (le certificat le suit) |
| `VIP` | `192.168.56.10` | le réseau host-only VirtualBox est ailleurs |
| `NODE1_IP` … `NODE3_IP` | `.11` `.12` `.13` | idem |
| `CLUSTER_CIDR` | `192.168.56.0/24` | idem — c'est ce que le pare-feu autorise entre nœuds |
| **`ADMIN_CIDR`** | `192.168.56.1/32` | **l'IP de votre poste** : c'est la liste blanche des interfaces d'administration |
| `PROFILE` | `full` | `light` sur une machine modeste : réduit les *heaps* JVM |
| `NODE_MEM` / `NODE_CPU` | 6144 / 4 | ressources par VM |
| `DATA_NETWORK_ENCRYPTED` | `true` | ne le passez à `false` qu'en connaissance de cause (ADR-0007) |
| `NFS_SERVER` | `192.168.56.11` | après une bascule NFS (voir [`07-PRA.md`](07-PRA.md)) |
| `REGISTRY` | `192.168.56.13:5000` | registre interne |
| `IMAGE_TAG` | `1.0.0` | **à incrémenter à chaque `make build`** : un tag existant n'est pas écrasé |
| `TZ` | `Europe/Paris` | fuseau des conteneurs (les sauvegardes restent en UTC) |
| `OFFSITE_S3_*` | vides | **à renseigner** pour satisfaire la règle 3-2-1 (§9) |
| `SMTP_*`, `ALERT_EMAIL_TO` | vides | notifications par courriel en plus des tickets GLPI |
| `DEMO_RATE`, `DEMO_SENSORS` | 20 / 50 | charge de la démo |

> **`ADMIN_CIDR` est le paramètre le plus important de ce fichier.** Il décide
> qui peut atteindre Traefik, Prometheus, Alertmanager, Grafana, Kibana et la
> console MinIO. Le laisser trop large ouvre six interfaces d'administration ;
> le rendu de configuration **échoue** s'il est vide, précisément pour que
> l'oubli ne produise pas une liste blanche vide (donc permissive).

L'inventaire Ansible (`ansible/inventory/hosts.yml`) reprend les mêmes adresses ;
il porte aussi `dw_keepalived_password`, à changer.

## 4. Étape 2 — `make vms provision`

```bash
make vms          # vagrant up : 3 VM bento/ubuntu-24.04, réseau host-only
make provision    # ansible-playbook site.yml
```

Ce que le *provisioning* installe, rôle par rôle :

| Rôle | Ce qu'il fait |
|---|---|
| `common` | paquets de base, fuseau, sysctls (`vm.max_map_count`, `swappiness=1`…), fail2ban |
| `docker` | Docker Engine **figé** (`apt-mark hold`), `daemon.json`, journalisation json-file |
| `firewall` | chaînes `DW-INPUT` et `DOCKER-USER`, persistées et rejouées au démarrage |
| `nfs-server` | sur node1 : les 5 exports (`/srv/nfs/...`) |
| `nfs-client` | paquets clients sur les trois |
| `keepalived` | VRRP, VIP, `chk_traefik` |
| `swarm` | `swarm init` puis `join`, et les 5 overlays |
| `node-labels` | les labels de placement, avec assertion de relecture |

**Vérifier :**

```bash
make provision            # une seconde exécution doit afficher changed=0
vagrant ssh node1 -c 'docker node ls'        # 3 nœuds Ready, un seul Leader
ping -c 3 192.168.56.10                      # la VIP répond
vagrant ssh node1 -c 'sudo iptables -S DW-INPUT'
```

L'idempotence n'est pas un détail de style : c'est ce qui permet de rejouer
`make provision` après un incident sans se demander ce qu'on va casser.

## 5. Étape 3 — `make secrets certs`

```bash
make secrets      # 41 secrets générés dans secrets/, puis créés dans Swarm
make certs        # CA interne, wildcard *.DOMAIN, certificats transport ES
```

`scripts/init-secrets.sh` génère ce qui manque et ne touche jamais à ce qui
existe. Les valeurs vivent dans `secrets/` (mode 700, dans `.gitignore`) **et**
comme objets Docker.

> **⚠️ Sauvegardez `secrets/` et `certs/ca.key` hors du cluster, dans un coffre,
> maintenant.**
> Sans `dw_restic_password`, aucune sauvegarde n'est restaurable : c'est la clé
> de chiffrement AES-256 du dépôt, et elle n'existe nulle part ailleurs. Sans la
> CA, il faut regénérer tous les certificats lors d'une reconstruction.
> `scripts/init-secrets.sh` le rappelle à la fin de son exécution.

```bash
scripts/init-secrets.sh --list     # ce qui existe localement et dans Swarm
```

## 6. Étape 4 — `make build`

```bash
make build        # déploie le registre interne si besoin, puis construit et pousse
```

Quatre images maison : `cassandra` (agent JMX embarqué), `alert2glpi`,
`backup-runner`, `demo-producer`. Elles sont poussées dans le registre interne
avec le tag `${IMAGE_TAG}`.

**`make build` refuse d'écraser un tag existant.** Après une modification :
incrémentez `IMAGE_TAG` dans `.env`, ou passez `--force` en connaissance de
cause. C'est ce qui rend le tag immuable en pratique et garantit que les trois
nœuds exécutent le même contenu.

## 7. Étape 5 — `make deploy`

```bash
make deploy               # les 5 stacks, dans l'ordre, avec attente de santé
make deploy-data          # une seule stack
make status               # services, nœuds, santé des clusters
```

L'ordre est imposé par les dépendances : GLPI ne peut pas s'installer avant
Galera, et Prometheus découvre ses cibles une fois les applications présentes.
`deploy.sh` enchaîne aussi les initialisations au bon moment :

| Après | Initialisation | Ce qu'elle fait |
|---|---|---|
| bootstrap Galera | `galera-bootstrap.sh` | la séquence en 5 étapes, y compris **le retrait du drapeau de bootstrap** que tout le monde oublie |
| `data` | `cassandra-init.sh` | remplace le superutilisateur par défaut, RF=3 sur `system_auth`, schéma, **aller-retour réel en LOCAL_QUORUM** |
| `data` | `es-init.sh` | mots de passe, rôles, ILM, templates, data streams, vues Kibana |
| `apps` | `glpi-init.sh` | **détruit les 4 mots de passe par défaut**, injecte les jetons API, vérifie par un vrai `initSession` |
| `backup` | `minio-init.sh` | buckets, versioning, politiques, comptes, **test d'isolation**, puis rappelle `es-init.sh` |

Comptez ~10 min : Cassandra et Elasticsearch démarrent lentement, et c'est
normal (`start_period` de 240 s sur Cassandra).

## 8. Étape 6 — Valider

```bash
make smoke ARGS=--no-backup     # avant la première sauvegarde
tests/smoke/network-isolation.sh
```

Le test de fumée passe par la **VIP**, en HTTPS, avec la CA interne : il éprouve
Keepalived, Traefik, le certificat, les routeurs et les middlewares, puis l'état
des trois clusters et la supervision. Il vérifie aussi que les interfaces
d'administration sont **protégées** — un 200 sans identifiants y est un échec.

## 9. Étape 7 — Accéder depuis le navigateur

Il n'y a pas de DNS dans le laboratoire :

```bash
make hosts | sudo tee -a /etc/hosts
```

| URL | Accès |
|---|---|
| `https://glpi.dockerwarts.lan` | public |
| `https://whoami.dockerwarts.lan` | public (validation) |
| `https://grafana.dockerwarts.lan` | liste blanche `ADMIN_CIDR` |
| `https://prometheus.dockerwarts.lan` | liste blanche + *basic auth* |
| `https://alertmanager.dockerwarts.lan` | idem |
| `https://kibana.dockerwarts.lan` | idem |
| `https://minio.dockerwarts.lan` | idem (console uniquement) |
| `https://traefik.dockerwarts.lan` | idem |

Le certificat est signé par la CA interne : importez `certs/ca.crt` dans le
navigateur, ou acceptez l'avertissement. Identifiants *basic auth* :
`admin` / `secrets/dw_traefik_admin_password.txt`.

## 10. Après l'installation

```bash
make backup-now        # première sauvegarde ; produit un rapport Markdown
make dr-drill          # exercice de reprise : restaure vraiment, à côté de la production
make deploy-demo       # charge de fond, à lancer AVANT make chaos
make chaos             # campagne HA (~30 min)
```

**Renseignez `OFFSITE_S3_*`** : sans copie hors site, la règle 3-2-1 n'est pas
satisfaite et perdre node3 perd toutes les sauvegardes. Le job le signale à
chaque passage.

## 11. Mode mono-nœud (développement)

> **Un document entier y est consacré** : [`09-test-local.md`](09-test-local.md)
> — préparation du poste, les quatre variables de `.env` à changer, ce qui se
> teste réellement en local et ce qui ne s'y teste pas.

```bash
make single-prepare ARGS=--fix    # Swarm, réseaux overlay, chemins hôte
make secrets certs build
make single
```

Un poste, un Swarm à un nœud, les mêmes définitions. C'est un mode d'itération
rapide, **pas** une petite production :

- Galera tourne seul : pas de quorum, pas de réplication synchrone ;
- Cassandra est en RF=1 ;
- Elasticsearch reste `yellow` **pour toujours** — c'est l'état correct sur un
  nœud, pas un problème ;
- Keepalived, la VIP et la bascule n'existent pas : Traefik prend les ports du
  poste.

`make smoke` signalera des échecs (3 nœuds, Galera à 3, ES `green`) et il a
raison : ces contrôles décrivent la topologie de production. Les fichiers
réellement déployés sont conservés dans `.rendered/single-<stack>.yml` — c'est
là qu'il faut regarder si un service se comporte étrangement dans ce mode. Les
limites sont détaillées dans [`06-haute-disponibilite.md`](06-haute-disponibilite.md#6-mode-mono-nœud--ce-quil-ne-teste-pas).

## 12. Dépannage

| Symptôme | Cause probable | Quoi faire |
|---|---|---|
| Un service reste `0/1` | contrainte de placement insatisfaite (labels absents) | `docker service ps <svc> --no-trunc` ; rejouer `make provision` |
| `wsrep_cluster_size = 1` | le drapeau de bootstrap n'a pas été retiré | `docker service inspect data_galera-1 \| grep GALERA_BOOTSTRAP` → doit valoir 0 ; sinon `scripts/galera-bootstrap.sh` |
| Galera ne démarre plus du tout | arrêt total, plus de nœud « sûr » | `scripts/galera-recover.sh --dry-run` puis sans l'option |
| Elasticsearch `red` | shards non alloués | `curl .../_cluster/allocation/explain` ; voir [`07-PRA.md`](07-PRA.md) |
| Elasticsearch refuse de démarrer | `vm.max_map_count` | déjà posé par le rôle `common` ; `sysctl vm.max_map_count` doit valoir 262144 |
| La VIP ne répond pas | Keepalived ou Traefik local | `journalctl -u keepalived -n 50` ; `curl http://127.0.0.1/ping` sur le nœud |
| 403 sur toutes les URL | votre IP est bannie par CrowdSec | `cscli decisions list` puis `cscli decisions delete --ip <ip>` |
| 403 sur les seules URL d'admin | `ADMIN_CIDR` ne contient pas votre IP | corriger `.env`, `make deploy-edge` |
| `image not found` au déploiement | `make build` non fait, ou `IMAGE_TAG` incohérent | `curl http://192.168.56.13:5000/v2/_catalog` |
| Une config modifiée n'est pas prise en compte | objet config Swarm immuable | le hash de contenu roule le service : redéployer la stack suffit |
| GLPI en erreur 500 après restauration | privilèges non rechargés | `FLUSH PRIVILEGES` (fait par `restore-galera.sh`) |
| Une sauvegarde échoue en boucle | MinIO plein, ou secret manquant | `make status` ; `MinIOCapacityLow` ; `scripts/init-secrets.sh --list` |

**Les journaux, dans l'ordre où on les regarde :**

```bash
make status                                  # vue d'ensemble
docker service ps <service> --no-trunc       # pourquoi une tâche ne démarre pas
docker service logs --tail 100 <service>     # ce que le service dit
journalctl -u docker -n 100                  # ce que le démon dit
https://kibana.dockerwarts.lan               # tous les logs, centralisés et cherchables
```

## 13. Désinstaller

```bash
make destroy       # vagrant destroy -f : les 3 VM disparaissent
```

Les secrets et certificats locaux restent dans `secrets/` et `certs/`.
Supprimez-les explicitement si vous ne comptez pas reconstruire — et vérifiez
d'abord que votre coffre en a une copie, car aucune sauvegarde restic n'est
lisible sans eux.

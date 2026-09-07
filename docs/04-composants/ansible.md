# Ansible — provisioning des hôtes

> Composant **hôte** (non dockerisé). Couvre `ansible/` en entier : configuration, inventaire,
> variables, playbooks et les 8 rôles, expliqués fichier par fichier et section par section.
>
> Décision structurante : [ADR-0002 — Provisioning par Vagrant + Ansible](../adr/0002-vagrant-ansible.md).

## 1. Rôle dans la plateforme

Ansible est la **source de vérité de tout ce qui vit sur l'hôte** : paquets, noyau, pare-feu,
NFS, Keepalived, moteur Docker et initialisation du Swarm. Tout le reste (services, réseaux
applicatifs, secrets, configurations) est décrit par les stacks Swarm.

La frontière est nette et voulue :

| Couche | Outil | Pourquoi |
|---|---|---|
| Machine (OS, noyau, pare-feu, VIP, NFS, moteur Docker) | **Ansible** | doit exister *avant* et *sous* Docker |
| Cluster (services, réseaux, secrets, configs) | **`docker stack deploy`** | c'est l'objet même du projet : une infra dockerisée |

Trois composants restent volontairement hors conteneur — le pare-feu, Keepalived et le serveur
NFS — parce que ce sont des fonctions d'hôte : un pare-feu doit filtrer **sous** le moteur de
conteneurs, et Keepalived surveille Docker (le mettre dans Docker serait circulaire, cf.
ADR-0003).

## 2. Arborescence

```
ansible/
├── ansible.cfg                     # configuration du contrôleur
├── .ansible-lint                   # profil production
├── requirements.yml                # collections Galaxy
├── inventory/hosts.yml.example     # inventaire modèle (hosts.yml est ignoré par git)
├── group_vars/all.yml              # variables partagées par tous les rôles
├── playbooks/
│   ├── site.yml                    # provisioning complet     → make provision
│   └── node-replace.yml            # remplacement d'un nœud   → PRA
└── roles/
    ├── common/          paquets, fuseau, sysctl, limites, SSH, fail2ban, logrotate, /etc/hosts
    ├── docker/          moteur Docker (dépôt officiel, version figée) + daemon.json
    ├── firewall/        iptables : chaînes DW-INPUT et DOCKER-USER
    ├── nfs-server/      exports NFSv4 (node1 uniquement)
    ├── nfs-client/      client NFSv4 (tous les nœuds)
    ├── keepalived/      VIP VRRP + check Traefik
    ├── swarm/           init / join des 3 managers + réseaux overlay
    └── node-labels/     labels de placement des services stateful
```

---

## 3. `ansible.cfg` — configuration du contrôleur

| Section / clé | Valeur | Explication |
|---|---|---|
| `inventory` | `inventory/hosts.yml` | inventaire par défaut ; l'exemple est versionné, le fichier réel non (il contient des chemins de clés privées) |
| `roles_path` | `roles` | c'est cette clé qui permet à `ansible-lint` de résoudre les rôles — d'où l'obligation de lancer `ansible-lint` **depuis `ansible/`** (`make lint-ansible` le fait) |
| `host_key_checking` | `False` | les VM sont recréées en permanence par Vagrant ; leur empreinte SSH change à chaque `make vms` |
| `stdout_callback` | `yaml` | sorties multi-lignes lisibles (diffs de fichiers de configuration) |
| `callbacks_enabled` | `profile_tasks` | affiche la durée de chaque tâche : indispensable pour comprendre un `provision` lent |
| `interpreter_python` | `/usr/bin/python3` | Ubuntu 24.04 n'a pas de `python` ; fige le choix au lieu de le laisser deviner |
| `gathering` | `smart` + `fact_caching` jsonfile | le rôle `swarm` a besoin des faits de **tous** les hôtes (jeton de join, IP) alors qu'il s'exécute hôte par hôte ; le cache (900 s) évite un re-gather complet |
| `forks` | `5` | 3 hôtes : la parallélisation totale est acquise, sans saturer un poste de développement |
| `display_skipped_hosts` | `False` | de nombreuses tâches sont conditionnées à un groupe (NFS, bootstrap) : les masquer rend la sortie exploitable |
| `[ssh_connection] pipelining` | `True` | supprime un aller-retour SFTP par tâche ; possible car `requiretty` est désactivé sur Ubuntu |
| `[privilege_escalation]` | `become: True`, `sudo`, `root` | tout ce que fait ce projet sur l'hôte est privilégié ; le déclarer une fois évite un `become:` sur chaque tâche |

## 4. `requirements.yml` — collections

| Collection | Contrainte | Usage |
|---|---|---|
| `community.docker` | `>=4.1.0,<5.0.0` | `docker_swarm`, `docker_swarm_info`, `docker_node`, `docker_node_info`, `docker_network` |
| `community.general` | `>=10.0.0,<12.0.0` | `timezone` |
| `ansible.posix` | `>=1.6.0,<3.0.0` | `sysctl` |

Les bornes hautes sont volontaires : une collection majeure change ses paramètres de modules et
casserait un `make provision` sans prévenir.

## 5. `inventory/hosts.yml.example`

C'est **le seul point de couplage** entre le code et l'infrastructure (ADR-0002) : remplacer
trois VM Vagrant par trois instances cloud se réduit à changer `ansible_host`, `ansible_user` et
la clé privée.

Trois groupes portent la topologie :

| Groupe | Contenu | Sens |
|---|---|---|
| `swarm_managers` | node1, node2, node3 | tous managers → quorum Raft 2/3 (ADR-0001) |
| `swarm_bootstrap` | node1 | **exactement un** hôte : celui qui exécute `docker swarm init` |
| `nfs_server` | node1 | **exactement un** hôte : celui qui exporte `/srv/nfs` (ADR-0006) |

Ces cardinalités sont vérifiées par un `assert` en `pre_tasks` de `site.yml` : une erreur
d'inventaire échoue immédiatement plutôt qu'au milieu du provisioning.

Variables par hôte :

| Variable | Rôle |
|---|---|
| `cluster_ip` | adresse annoncée au Swarm, à Keepalived et au NFS. Distincte d'`ansible_host` : sur un cloud, l'une est publique et l'autre privée |
| `keepalived_priority` | 150 / 100 / 50 — voir §9 |
| `swarm_labels` | labels de placement appliqués par le rôle `node-labels` (§11) |

**Déplacer le groupe `nfs_server` sur un autre hôte est la procédure de bascule NFS du PRA** :
c'est tout ce que le code demande, le reste est une restauration restic et un `make deploy-apps`.

## 6. `group_vars/all.yml` — variables partagées

Le fichier reflète `.env.example` : `.env` sert aux stacks, `group_vars/all.yml` sert aux hôtes.
Les valeurs communes (VIP, CIDR, domaine) sont dupliquées mais jamais divergentes en pratique,
car le déploiement complet part des deux fichiers d'exemple.

| Groupe de variables | Contenu et raison |
|---|---|
| Topologie | `dw_domain`, `dw_vip`, `dw_cluster_cidr`, `dw_admin_cidr`, `dw_cluster_interface` (`enp0s8` = 2ᵉ carte du réseau host-only VirtualBox ; à changer pour du cloud) |
| Docker | `dw_docker_version` **figée** (`apt-mark hold`) : une montée de version du moteur sous un Swarm vivant est une décision d'exploitation, pas un effet de bord d'`apt` ; `dw_registry_host` déclaré `insecure-registries` |
| Swarm | `dw_swarm_default_addr_pool` (`10.20.0.0/16`, /24 par réseau) : plage **prévisible**, sur laquelle les règles `DOCKER-USER` s'appuient |
| Réseaux | `dw_overlay_networks` : les 5 overlays du CDC §5.4, avec `internal` et `encrypted` par réseau |
| NFS | `dw_nfs_root`, `dw_nfs_exports` (4 répertoires GLPI + 1 pour les métriques de sauvegarde), avec `owner`/`group` numériques (`anonuid`/`anongid`) |
| Keepalived | `dw_keepalived_router_id`, `dw_keepalived_check_weight` (**−60**, voir §9), `dw_keepalived_password` |
| Durcissement | `dw_timezone`, `dw_sysctls` |
| Noms publiés | `dw_published_hostnames` : la liste des noms routés par Traefik, utilisée pour `/etc/hosts`, `make hosts`, les sondes blackbox et le smoke test |

Détail des `sysctl` — chacun a une cause précise :

| Paramètre | Valeur | Pourquoi |
|---|---|---|
| `vm.max_map_count` | `262144` | Elasticsearch refuse de démarrer en dessous (mmap des segments Lucene) |
| `net.ipv4.ip_nonlocal_bind` | `1` | Keepalived doit pouvoir préparer la VIP avant de la posséder |
| `fs.inotify.max_user_instances` / `max_user_watches` | `512` / `524288` | Fluent Bit suit des dizaines de fichiers de logs de conteneurs |
| `vm.swappiness` | `1` | le swap est fatal aux bases JVM (pauses GC de plusieurs secondes) |
| `net.core.somaxconn` | `4096` | file d'attente d'acceptation : Traefik et Cassandra la saturent en pic |
| `net.ipv4.tcp_keepalive_time` | `300` | détecte plus tôt les connexions mortes vers un nœud disparu |

---

## 7. Rôle `common`

Base OS commune aux trois nœuds, dans cet ordre :

1. **Fuseau horaire** (`Europe/Paris`) — les horodatages des logs et des tickets GLPI doivent
   concorder.
2. **Paquets de base** — `chrony` (Galera et Cassandra sont sensibles à la dérive d'horloge),
   `jq` (runbooks et tests), `nfs-common` (tous les nœuds montent le NFS GLPI),
   `iptables-persistent`, `fail2ban`, `unattended-upgrades`.
3. **`sysctl`** — appliqués à chaud **et** persistés dans `/etc/sysctl.d/99-dockerwarts.conf`,
   pour qu'un redémarrage ne casse pas Elasticsearch.
4. **Swap désactivé** — à chaud (`swapoff -a`) et dans `/etc/fstab`.
5. **Limites** (`/etc/security/limits.d/99-dockerwarts.conf`) — `nofile 262144` et
   `memlock unlimited` : Elasticsearch utilise `bootstrap.memory_lock=true`, Cassandra ouvre
   beaucoup de SSTables.
6. **Durcissement SSH** — clé uniquement, `PermitRootLogin no`, `MaxAuthTries 3`. Écrit dans
   `sshd_config.d/` (pas d'édition du fichier principal : idempotent et réversible).
7. **fail2ban** — jail `sshd` **uniquement**. La protection HTTP est le travail de CrowdSec
   (ADR-0004) ; `ignoreip` couvre le sous-réseau du cluster et le poste d'administration, pour ne
   pas s'auto-bannir pendant un test.
8. **`unattended-upgrades`** activé, **avec une liste noire** `docker-ce`, `docker-ce-cli`,
   `containerd.io` : les mises à jour de sécurité sont souhaitables, un redémarrage automatique
   du moteur Docker ne l'est pas.
9. **Rotation du log Traefik** — `/var/log/traefik/*.log`, `copytruncate` **obligatoire** : deux
   lecteurs suivent ce fichier (l'agent CrowdSec et Fluent Bit) ; une rotation par renommage leur
   ferait perdre le fichier, `copytruncate` préserve l'inode.
10. **`/etc/hosts`** — noms des nœuds + tous les noms publiés pointant sur la VIP, dans un bloc
    `blockinfile` marqué (donc idempotent et supprimable).

## 8. Rôle `docker` et `daemon.json`

Le rôle installe le dépôt officiel Docker, la version **figée**, la maintient (`hold`), installe
le SDK Python (requis par les modules `community.docker` ; `--break-system-packages` est
nécessaire sur le Python « externally managed » d'Ubuntu 24.04), puis dépose `daemon.json`.

Le `template` valide le JSON **avant** de l'installer (`validate:`), ce qui évite le scénario
classique d'un moteur Docker qui refuse de redémarrer à cause d'une virgule.

Les handlers sont **flushés explicitement** en fin de rôle : le rôle `swarm` qui suit a besoin
d'un démon vivant ayant déjà appliqué `daemon.json`.

`daemon.json`, clé par clé :

| Clé | Valeur | Explication |
|---|---|---|
| `log-driver` / `log-opts` | `json-file`, 10 Mo × 3, labels Swarm | **Volontairement pas le driver `fluentd`** : avec `fluentd`, une indisponibilité de Fluent Bit bloquerait l'écriture des conteneurs. Fluent Bit *tail* les fichiers, donc un incident de collecte ne fait perdre que des logs, jamais un service. Les `labels` exportés permettent au filtre Lua d'attribuer chaque ligne à son service Swarm |
| `metrics-addr` | `<cluster_ip>:9323` | métriques du moteur, scrappées par Prometheus. Liées à l'IP du cluster (pas `0.0.0.0`) et filtrées par le pare-feu |
| `insecure-registries` | `${REGISTRY}` | registry interne en HTTP clair, sur réseau privé filtré (CDC §10.2) ; l'option TLS est documentée dans `docs/08-exploitation.md` |
| `default-address-pools` | `172.20.0.0/16` (bridge) + `10.20.0.0/16` (overlay), /24 | plages **prévisibles**, sur lesquelles les règles `DOCKER-USER` reposent. Sans cela, Docker choisit des plages variables et le filtrage devient impossible à écrire |
| `live-restore` | `false` | incompatible avec le mode Swarm ; les tâches sont replanifiées par Swarm de toute façon |
| `userland-proxy` | `false` | supprime le proxy en espace utilisateur : le trafic des ports publiés traverse alors réellement `DOCKER-USER`, condition de l'efficacité du pare-feu |
| `default-ulimits` | `nofile 262144`, `memlock -1` | propagés à tous les conteneurs (ES, Cassandra) |
| `storage-driver` | `overlay2` | standard sur Ubuntu 24.04 |

## 9. Rôle `firewall`

Détaillé dans [`docs/03-reseau-securite.md`](../03-reseau-securite.md) ; voici la logique du rôle.

**Problème.** Un `iptables-restore` de la table `filter` complète effacerait les chaînes que
Docker maintient (`DOCKER`, `DOCKER-ISOLATION-STAGE-*`, `DOCKER-USER`) et couperait le réseau des
conteneurs jusqu'au redémarrage du démon.

**Solution.** Le rôle ne possède que **deux chaînes**, qu'il reconstruit intégralement :

- `DW-INPUT` — chaîne propre, appelée depuis `INPUT` (politique `DROP`) par une unique règle de
  saut, ajoutée avec `iptables -C` puis `-A` (donc jamais en double).
- `DOCKER-USER` — créée par Docker, évaluée **avant** ses propres règles `FORWARD` : c'est le
  seul endroit où les ports publiés par des conteneurs peuvent être filtrés.

Comme les deux chaînes sont vidées puis reremplies, le script est **idempotent par
construction** : deux exécutions produisent exactement le même jeu de règles (vérifié en phase 0
par comparaison d'empreintes).

**Persistance.** Le script est installé en tant que *plugin* `netfilter-persistent`
(`plugins.d/10-dockerwarts`, conformément au CDC §6.1) **et** rejoué au démarrage par l'unité
`dockerwarts-firewall.service`, ordonnée `After=docker.service` : `DOCKER-USER` n'existe pas
avant que le démon ne l'ait créée.

`stop` est délibérément **permissif** (politiques `ACCEPT`, chaînes supprimées) : c'est la
commande qu'un opérateur lance après s'être verrouillé dehors, et celle que
`netfilter-persistent` appelle à la désinstallation.

Le rôle se termine par un `assert` sur la présence de la règle marqueur `DW-DOCKER-USER-END` :
c'est le critère d'acceptation 0.5, vérifié par le provisioning lui-même.

## 10. Rôles `nfs-server` et `nfs-client`

`nfs-server` (node1) crée les 5 répertoires exportés et écrit `/etc/exports`. Options, une par
une :

| Option | Raison |
|---|---|
| `rw` | GLPI écrit ses pièces jointes ; les jobs de sauvegarde écrivent leurs fichiers `.prom` |
| `sync` | un écrit n'est acquitté qu'une fois sur disque : une pièce jointe doit survivre à un crash de nœud |
| `no_subtree_check` | standard pour un export de répertoire entier, et nettement plus rapide |
| `root_squash` | root dans un conteneur n'est pas root sur l'export |
| `no_wdelay` | les fichiers de métriques sont petits et écrits atomiquement : ne pas les retarder |
| `anonuid`/`anongid` | identités numériques stables (1000 pour GLPI, 65534 pour `nginx`), le mapping NFSv4 par nom n'étant pas fiable entre conteneurs |

Le rôle se termine par un `assert` sur `exportfs -s` : un export manquant échoue le provisioning.

`nfs-client` installe `nfs-common` sur **tous** les nœuds. Il n'y a **aucune entrée `fstab`** :
les volumes GLPI sont déclarés dans `stacks/apps.yml` avec le driver `local` et `type: nfs`, donc
c'est le démon Docker qui monte l'export, au moment où il en a besoin.

## 11. Rôle `keepalived`

Voir [`keepalived.md`](keepalived.md) pour le composant. Côté rôle :

- installation du paquet, du script `/usr/local/sbin/chk_traefik` et de `keepalived.conf` ;
- `enable_script_security` + `script_user root` : Keepalived 2.x refuse d'exécuter un script d'un
  répertoire inscriptible par autrui ;
- **VRRP en unicast** (`unicast_src_ip` / `unicast_peer`) plutôt qu'en multicast : le multicast
  est capricieux sur les réseaux host-only VirtualBox et interdit sur la plupart des clouds ;
  la règle pare-feu multicast reste ouverte pour rester compatible d'un basculement en multicast ;
- **arithmétique des priorités** : 150 / 100 / 50, `weight -60` sur le check. Un node1 dont
  Traefik est en panne tombe à 90, en dessous de node2 (100) : la VIP part. Un node2 en panne
  tombe à 40, en dessous de node3 (50). Le choix de −60 est donc contraint : il doit être
  strictement supérieur à l'écart entre deux priorités consécutives (50) et strictement inférieur
  au double (100), faute de quoi la bascule serait soit impossible, soit systématique ;
- `preempt_delay 5` : node1 reprend la VIP quand il redevient sain, après 5 s de stabilité ;
- le rôle est appliqué **en dernier** dans `site.yml` : son check interroge Traefik, déployé plus
  tard. Tant qu'aucun Traefik ne tourne, les trois nœuds échouent le check de façon identique et
  node1, priorité la plus haute, garde la VIP — ce qui est le comportement voulu.

## 12. Rôle `swarm`

1. `docker swarm init` sur l'unique hôte de `swarm_bootstrap`, avec
   `default_addr_pool` = `10.20.0.0/16` (cohérent avec `daemon.json`).
   `autolock_managers: false` : un redémarrage non surveillé doit ramener le manager sans qu'un
   opérateur saisisse une clé de déverrouillage.
   `task_history_retention_limit: 5` borne le journal Raft sur de petits disques.
2. Lecture du jeton de join sur le nœud de bootstrap, puis `set_fact` pour le diffuser à tous les
   hôtes (d'où le `fact_caching` d'`ansible.cfg`).
3. `state: join` sur les deux autres nœuds, **en manager**.
4. `assert` sur le nombre de nœuds enregistrés → critère d'acceptation 0.3.
5. Création des **5 réseaux overlay**, une seule fois, délégué au nœud de bootstrap :

| Réseau | `internal` | Chiffré | Raison |
|---|---|---|---|
| `edge` | non | non | doit joindre l'extérieur (Traefik) |
| `data` | oui | **oui** | trafic base de données inter-nœuds ; le chiffrement IPsec est ce qui autorise l'API HTTP d'Elasticsearch en clair (ADR-0007) |
| `monitoring` | oui | non | métriques internes, volume élevé, pas de donnée sensible |
| `mgmt` | oui | non | accès au socket proxy |
| `crowdsec` | oui | non | LAPI ↔ agents ↔ bouncer |

Tous sont `attachable: true` : `tests/smoke/network-isolation.sh` a besoin de rattacher un
conteneur jetable à `edge` pour prouver qu'il **ne** joint **pas** `galera-1:3306`.

Les réseaux sont créés ici, pas dans les stacks, et référencés `external: true` : supprimer une
stack ne détruit donc jamais un réseau qu'une autre utilise encore.

## 13. Rôle `node-labels`

Swarm n'a pas de `StatefulSet` (ADR-0001) : chaque membre d'un cluster stateful est un service
distinct, épinglé par un label, avec un volume **local**.

| Nœud | Labels |
|---|---|
| node1 | `cassandra=1 es=1 galera=1 prometheus=a nfs=true` |
| node2 | `cassandra=2 es=2 galera=2 prometheus=b` |
| node3 | `cassandra=3 es=3 galera=3 minio=true crowdsec_lapi=true registry=true` |

`labels_state: replace` rend le rôle **autoritaire** : un label retiré de l'inventaire est
réellement retiré du nœud. Un `assert` relit ensuite les labels posés.

C'est ce rôle qui fait fonctionner le remplacement de nœud : on rejoint la machine neuve, on
rejoue le rôle, et Swarm replanifie dessus les services épinglés.

## 14. `playbooks/site.yml`

L'ordre des rôles n'est pas cosmétique :

```mermaid
flowchart LR
  C[common] --> D[docker]
  D --> F[firewall]
  F --> N[nfs-server / nfs-client]
  N --> S[swarm]
  S --> L[node-labels]
  L --> K[keepalived]
```

- `docker` **avant** `firewall` : la chaîne `DOCKER-USER` n'existe pas avant le démon.
- `firewall` **avant** `swarm` : le join a besoin de 2377/7946/4789 ouverts entre les nœuds.
- `keepalived` **en dernier** : voir §11.

Les `pre_tasks` valident l'inventaire (cardinalités des groupes, variables obligatoires) : une
erreur de saisie échoue en deux secondes plutôt qu'au milieu du provisioning.

Les `post_tasks` impriment un récapitulatif et la commande suivante — le playbook explique
lui-même la suite.

## 15. `playbooks/node-replace.yml`

Procédure PRA de remplacement définitif d'un nœud :

1. depuis un manager **survivant**, `docker node rm --force` du nœud disparu ;
2. provisioning complet de la machine de remplacement (mêmes rôles que `site.yml`) ;
3. réapplication des labels → Swarm replanifie les services épinglés, **avec des volumes locaux
   vides** ;
4. impression du runbook de resynchronisation par moteur.

L'étape 4 est **volontairement non automatisée** : chaque moteur demande une décision.

| Moteur | Action |
|---|---|
| **Galera** | rien : SST automatique depuis un donneur. Surveiller `wsrep_cluster_size = 3` |
| **Cassandra** | le nœud doit **remplacer** le disparu, pas s'ajouter en 4ᵉ membre : `JVM_OPTS=-Dcassandra.replace_address_first_boot=<ancienne adresse>`, puis `nodetool repair -pr` |
| **Elasticsearch** | rien : le cluster réalloue les répliques seul (`yellow` → `green`) |

Automatiser l'option Cassandra serait dangereux : appliquée à tort (nœud non réellement mort),
elle corromprait la topologie de l'anneau.

## 16. Idempotence et qualité

- `make provision-check` (`--check --diff`) : le second passage doit rapporter **0 changed**
  (critère 0.2). Les seules tâches déclarées `changed_when: false` sont des lectures
  (`docker info`, `exportfs -s`, `iptables -S`, `ping`).
- `make lint-ansible` : `ansible-lint` en profil **production**, sans exception autre que les
  noms de rôles à tiret (convention du CDC) et l'absence de bloc Galaxy (aucun rôle n'est publié).
- Aucun `shell:` là où un module existe. Les trois `command:` restants sont des vérifications en
  lecture seule et le rappel du script pare-feu, pour lequel il n'existe pas de module.

## 17. Points d'attention

| Point | Détail |
|---|---|
| `dw_cluster_interface` | vaut `enp0s8` (2ᵉ carte VirtualBox). Sur du cloud, à mettre à l'interface portant l'IP privée, sinon Keepalived ne démarre pas |
| `dw_keepalived_password` | mot de passe VRRP, **pas** un secret Docker : il configure un service d'hôte. À surcharger via l'inventaire ou Ansible Vault |
| Version de Docker | figée et bloquée. La monter est une procédure d'exploitation documentée, à faire nœud par nœud avec drain |
| Cache de faits | `/tmp/dockerwarts-facts`, TTL 900 s. Un `provision` relancé après une longue interruption re-collecte les faits, c'est normal |
| Ordre de `flush_handlers` | trois rôles forcent le flush (docker, firewall, nfs-server). C'est ce qui garantit que le rôle suivant travaille sur un système déjà reconfiguré |

# GLPI — outil de ticketing

> Composant de la stack `apps`. Couvre `stacks/apps.yml`, `config/glpi/php.ini`,
> `scripts/glpi-init.sh` et les volumes NFS.
>
> Décision structurante : [ADR-0006 — NFS pour les fichiers GLPI, SPOF assumé](../adr/0006-nfs-spof-assume.md).

## 1. Rôle dans la plateforme

GLPI est l'**outil de ticketing** demandé par l'énoncé (exigence F1). Il joue ici deux rôles :

1. **service utilisateur** : la seule application réellement publique de la plateforme, accessible
   en HTTPS via la VIP, sans liste blanche d'IP ;
2. **destination de la boucle d'incident** : chaque alerte Prometheus critique devient
   automatiquement un ticket, créé par `alert2glpi` via l'API REST (ADR-0009), et résolu
   automatiquement au retour à la normale. C'est ce qui rend le monitoring « clair » au sens de
   l'énoncé : une alerte débouche sur une action tracée.

## 2. Topologie

| Service | Replicas | Placement | Réseaux | Rôle |
|---|---|---|---|---|
| `glpi-web` | 2 | `max_replicas_per_node: 1` | `edge`, `data` | interface web et API REST |
| `glpi-cron` | 1 | flottant | `data` | **unique** exécuteur des actions automatiques |

### Pourquoi exactement un `glpi-cron`

GLPI traite en file d'attente ses actions automatiques : notifications, inventaire, purges,
escalade de tickets. Deux exécuteurs concurrents traiteraient **deux fois la même file** :
notifications en double, compteurs faussés, inventaire dupliqué.

D'où :

- `GLPI_CRON_ENABLED: "false"` sur `glpi-web`, qui désactive la boucle cron interne de l'image ;
- un service `glpi-cron` à **1 replica** avec `order: stop-first` — jamais deux à la fois, même
  une seconde pendant une mise à jour.

Le service est une **boucle** (`glpi:cron --force` toutes les 60 s) et non un conteneur qui se
termine : swarm-cronjob pilote les jobs de *sauvegarde*, mais le cron GLPI doit tourner chaque
minute, ce qui signifierait un démarrage de conteneur par minute — bien plus coûteux qu'un
processus persistant.

La boucle attend d'abord que la base soit installée (`database:check`) : au tout premier
déploiement, `glpi-cron` démarre avant que `glpi-init.sh` n'ait fini, et sans cette attente il
échouerait en boucle avec des erreurs SQL trompeuses.

## 3. Sessions collantes — le détail qui casse tout si on l'oublie

GLPI stocke les sessions PHP sur le **système de fichiers local de chaque replica**, pas en base.
Sans épinglage, un utilisateur serait déconnecté environ une requête sur deux.

```yaml
traefik.http.services.glpi.loadbalancer.sticky.cookie: "true"
traefik.http.services.glpi.loadbalancer.sticky.cookie.name: "glpi_srv"
traefik.http.services.glpi.loadbalancer.sticky.cookie.secure: "true"
traefik.http.services.glpi.loadbalancer.sticky.cookie.httponly: "true"
traefik.http.services.glpi.loadbalancer.sticky.cookie.samesite: "lax"
```

`secure` (uniquement en HTTPS), `httponly` (JavaScript ne peut pas le lire), `samesite=lax`
(protection CSRF sans casser la navigation).

### Pourquoi les sessions ne sont pas sur NFS

Ce serait techniquement possible et supprimerait le besoin d'épinglage. C'est refusé : un fichier
de session est écrit **à chaque requête**, et les allers-retours NFS domineraient le temps de
réponse de toute l'application.

Le compromis est explicite : perdre un replica déconnecte ses utilisateurs — 30 secondes de gêne,
contre un coût de latence permanent. Le healthcheck Traefik
(`loadbalancer.healthcheck.path: /status.php`) fait que le trafic cesse d'aller vers un replica
malade **avant** que Swarm ne le remarque.

## 4. Les volumes NFS — le seul stockage partagé de la plateforme

GLPI conserve deux natures d'état : sa **base** (Galera, répliquée) et ses **fichiers**. Avec deux
replicas sur deux nœuds, les fichiers doivent être partagés.

| Volume | Contenu | Conséquence si perdu |
|---|---|---|
| `glpi_files` | pièces jointes, documents générés, logs applicatifs | documents inaccessibles |
| `glpi_config` | `config_db.php`, clé de chiffrement GLPI | GLPI ne démarre plus |
| `glpi_plugins` | plugins installés | fonctionnalités manquantes |
| `glpi_marketplace` | téléchargements du marketplace | reconstructible |

### Options de montage, une par une

```yaml
o: "addr=${NFS_SERVER},rw,nfsvers=4.1,soft,timeo=50,retrans=3,noatime"
```

| Option | Raison |
|---|---|
| `nfsvers=4.1` | pas de `rpcbind`, pas de démon de verrous séparé : **un seul port** (2049) à filtrer |
| **`soft`** | **le choix le plus important**. Avec `hard`, une panne NFS bloque le processus en sommeil ininterruptible — le conteneur ne peut même plus être tué. Avec `soft`, l'E/S échoue, GLPI renvoie une erreur pour la pièce jointe, et le reste de l'application continue. **Dégradé vaut mieux que figé** |
| `timeo=50` | 5 s par tentative (en décisecondes) |
| `retrans=3` | ~15 s avant d'abandonner : borné, pas infini |
| `noatime` | GLPI lit des pièces jointes en permanence ; écrire une date d'accès à chaque lecture serait des allers-retours NFS pour rien |

Le montage est effectué par le **démon Docker** (driver `local`, `type: nfs`), pas par une entrée
`fstab`. Conséquence directe : **déplacer l'export est un changement de `NFS_SERVER` dans `.env`
suivi d'un `make deploy-apps`** — c'est exactement la procédure de bascule du PRA.

### Le SPOF, assumé et couvert

node1 est un point de défaillance unique pour les *fichiers* GLPI (pas pour le service : la base
est en Galera). C'est le choix de l'ADR-0006, et il est couvert :

| Mesure | Détail |
|---|---|
| Sauvegarde | `backup-glpi-files`, quotidienne, restic, rétention 7 j / 4 sem / 6 mois |
| Détection | `NodeDown` sur node1 → ticket GLPI automatique |
| Bascule | procédure documentée, RTO 30 min (`docs/07-PRA.md`) |
| Comportement dégradé | grâce à `soft` : GLPI reste utilisable, seules les pièces jointes échouent |

L'alternative (GlusterFS répliqué) supprimerait le SPOF mais ajouterait un système distribué à
exploiter, gourmand et fragile sur de petites VM — disproportionné pour quelques centaines de Mo
de pièces jointes.

## 5. `config/glpi/php.ini`

Le préfixe `zz-` garantit un chargement **en dernier**, donc la priorité sur les valeurs de
l'image.

| Réglage | Valeur | Raison |
|---|---|---|
| `memory_limit` | 256M | minimum documenté par GLPI ; en dessous il refuse de s'installer ou avertit en permanence |
| `max_execution_time` | 600 | un import d'inventaire ou l'installation d'un gros plugin prend réellement des minutes. Le défaut de 30 s les fait échouer à mi-parcours, en laissant des données partielles |
| `upload_max_filesize` / `post_max_size` | 64M / 64M | `post_max_size` **doit** être ≥ `upload_max_filesize`, sinon PHP jette le fichier en silence et GLPI signale une pièce jointe vide sans erreur |
| `session.cookie_secure` / `httponly` / `samesite` | 1 / 1 / Lax | cohérent avec le cookie collant de Traefik |
| `session.use_strict_mode` | 1 | PHP refuse un identifiant de session qu'il n'a pas généré : ferme la fixation de session |
| `expose_php` | Off | pas d'en-tête `X-Powered-By` |
| `display_errors` | Off | ne jamais afficher de trace à un navigateur : fuite de chemins, de versions, parfois d'identifiants |
| `error_log` | `/dev/stderr` | les erreurs PHP sont collectées par Fluent Bit comme n'importe quel log, au lieu de dormir dans un fichier |
| `disable_functions` | `exec, shell_exec, system, …` | transforme une vulnérabilité d'écriture de fichier en simple écriture, au lieu d'une exécution de code |
| `opcache.*` | activé, 192 Mo, 20 000 fichiers | **le facteur de performance le plus important** : sans OPcache, chaque requête recompile des milliers de fichiers PHP |
| `opcache.validate_timestamps` | **1** | reste activé : un plugin installé via le marketplace modifie des fichiers sur disque, et à 0 ces changements n'apparaîtraient qu'au redémarrage du conteneur |

## 6. `scripts/glpi-init.sh`

Idempotent, exécuté après chaque déploiement de `apps`. Huit étapes.

### 6.1 Installation (étape 2)

Le test d'existence porte sur la **table `glpi_configs`**, pas sur un fichier marqueur. Un marqueur
sur NFS survivrait à une restauration de base et ferait sauter une installation pourtant
nécessaire — exactement le scénario d'une reprise après sinistre.

### 6.2 Les mots de passe par défaut (étape 3) — la plus importante

Une installation GLPI neuve embarque quatre comptes aux mots de passe **publiés** :

| Compte | Mot de passe par défaut | Traitement |
|---|---|---|
| `glpi` | `glpi` (super-admin) | **conservé**, mot de passe remplacé par `dw_glpi_admin_password` |
| `tech` | `tech` | **désactivé**, mot de passe détruit |
| `normal` | `normal` | **désactivé**, mot de passe détruit |
| `post-only` | `postonly` | **désactivé**, mot de passe détruit |

Les trois derniers sont **désactivés** plutôt que dotés d'un nouveau mot de passe : cette
plateforme a exactement un administrateur humain et un compte machine. Un compte désactivé ne peut
pas être attaqué par force brute du tout.

Ils reçoivent quand même un mot de passe aléatoire **en plus** de `is_active = 0` : la
désactivation seule laisserait un mot de passe connu en place si quelqu'un réactivait le compte
plus tard.

Le hachage est produit par `password_hash(..., PASSWORD_BCRYPT)` **dans le conteneur** — c'est la
seule façon d'obtenir un hachage que GLPI accepte. Le script vérifie que le résultat commence bien
par `$2y$`, et refuse de continuer sinon.

C'est l'étape qu'une installation manuelle repousse toujours. Elle est automatisée précisément
pour cela.

### 6.3 API REST et proxy de confiance (étape 4)

```sql
enable_api = 1
enable_api_login_credentials = 1
trusted_proxies = 10.20.0.0/16
url_base = https://glpi.dockerwarts.lan
```

Le proxy de confiance n'est pas cosmétique : sans lui, GLPI journalise la passerelle overlay comme
source de **toutes** les connexions, ce qui rend son propre journal d'audit sans valeur.

`url_base` conditionne les liens dans les notifications et les réponses de l'API : mal réglé, les
courriels de notification pointent vers `http://<id-conteneur>/`.

### 6.4 Le compte `alertmanager` et les jetons (étape 5)

Deux jetons sont nécessaires à l'API GLPI :

| Jeton | Identifie | Secret |
|---|---|---|
| `app_token` | le **client** (ici alert2glpi) | `dw_glpi_app_token` |
| `user_token` | l'**utilisateur** au nom duquel on agit | `dw_glpi_user_token` |

**Inversion délibérée** : les jetons sont générés par `scripts/init-secrets.sh` et **injectés**
dans GLPI, au lieu d'être générés par GLPI et relus. Deux bénéfices :

1. le script devient **idempotent** — le rejouer restaure les mêmes jetons ;
2. il n'y a **pas de problème d'ordre** : alert2glpi peut être déployé avant, après ou en même
   temps que ce script.

Le compte reçoit le profil **Technicien**, pas Super-Admin : le pont n'a besoin que de créer et de
mettre à jour des tickets. Super-Admin permettrait à un webhook compromis de reconfigurer GLPI.

Il reçoit un mot de passe aléatoire **inutilisable** : il s'authentifie uniquement par jeton, et
lui donner un mot de passe exploitable ajouterait une surface d'attaque pour rien.

### 6.5 Vérification de bout en bout (étape 8)

Le script ne se contente pas de vérifier que `enable_api = 1`. Il exécute un **vrai
`initSession`** avec les deux jetons réels — exactement ce que fera alert2glpi — et vérifie qu'un
`session_token` revient. Puis il ferme la session : une session abandonnée reste en table et
compte dans la limite de sessions concurrentes.

## 7. Supervision

| Élément | Détail |
|---|---|
| Sonde | blackbox HTTP via la VIP sur `https://glpi.dockerwarts.lan/`, code 200 et corps contenant `GLPI` |
| Healthcheck | `/status.php` doit contenir `GLPI_OK` — cet endpoint ne répond `OK` que si la **connexion base fonctionne aussi**. Un simple `/` renverrait 200 depuis Apache seul, masquant une base cassée |
| Alertes | `GLPIDown` (sonde en échec 1 min, **critical**), `GLPISlow` (p95 > 2 s, warning) |
| Dashboards | « Vue d'ensemble » (disponibilité), « Traefik » (latences par routeur) |
| Logs | Apache et PHP sur stdout → `logs-docker`, attribués au service par le filtre Lua |

`GLPISlow` à 2 s est aligné sur `long_query_time = 2` de Galera : une page lente et une requête
lente tombent dans la même fenêtre et deviennent corrélables.

## 8. Sauvegarde

| Élément | Job | Méthode |
|---|---|---|
| Base `glpi` | `backup-galera`, 02:00 | `mariadb-dump --single-transaction` de toutes les bases |
| Fichiers NFS | `backup-glpi-files`, 02:30 | `restic backup /data` (montage NFS en lecture seule) |

**Le duo est indissociable** : la base sans les fichiers donne des tickets dont les pièces jointes
sont des liens morts ; les fichiers sans la base donnent des documents orphelins. Les deux jobs
tournent à 30 minutes d'intervalle, et `make dr-drill` vérifie les deux.

Restauration : `scripts/restore/restore-galera.sh` et `scripts/restore/restore-glpi-files.sh`
(qui arrête `glpi-web` et `glpi-cron` pendant l'opération — restaurer sous une application vivante
produirait un état incohérent).

## 9. Points d'attention

| Point | Détail |
|---|---|
| Un seul `glpi-cron` | deux exécuteurs traiteraient la file deux fois. `order: stop-first` est obligatoire |
| Sessions locales | c'est ce qui impose le cookie collant. Ne pas retirer les labels sticky |
| NFS `soft` | délibéré : dégradé plutôt que figé. Ne pas passer en `hard` |
| `glpi_config` sur NFS | contient la clé de chiffrement GLPI. Le perdre empêche de déchiffrer les mots de passe stockés (collecteurs de courriel, connecteurs) |
| Première installation | `db:install` prend quelques minutes. `start_period: 120s` sur le healthcheck n'est pas de la marge |
| Montée de version de l'image | GLPI exige `database:update` après un changement de version. Le script le lance systématiquement, mais **sauvegarder la base avant** |
| Comptes par défaut | vérifier après chaque restauration que `glpi-init.sh` a bien été rejoué : une base restaurée depuis une sauvegarde antérieure au durcissement réintroduirait les mots de passe publiés |

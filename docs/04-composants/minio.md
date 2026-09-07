# MinIO — dépôt S3 des sauvegardes

> **Rôle** : fournir l'API S3 sur laquelle reposent **toutes** les sauvegardes du projet — le
> dépôt restic (dumps SQL, snapshots Cassandra, fichiers GLPI, TSDB Prometheus, base CrowdSec,
> état du cluster) et le *repository* de snapshots natifs d'Elasticsearch.
> **Références** : CDC §7.7, §9.1 ; ADR-0008 (MinIO + restic) ; ADR-0010 (métriques).
> **Fichiers** : `stacks/backup.yml` (service `minio`), `config/minio/policies/*.json`,
> `scripts/minio-init.sh`.

---

## 1. Pourquoi un S3 interne plutôt qu'un disque

restic sait écrire sur un système de fichiers local. Trois raisons de ne pas le faire ici.

1. **Un dépôt local est sur un nœud.** Les jobs de sauvegarde s'exécutent sur les trois nœuds
   (chacun est épinglé là où sont les données qu'il archive). Un dépôt sur disque supposerait un
   partage réseau — donc NFS, donc le SPOF de node1 (ADR-0006) — pour l'ensemble des
   sauvegardes, et non plus pour les seuls fichiers GLPI.
2. **Elasticsearch ne sait pas sauvegarder autrement.** Le plugin `repository-s3` est le seul
   mécanisme de snapshot utilisable ici ; un *repository* de type `fs` exigerait un
   `path.repo` monté à l'identique sur les trois nœuds ES.
3. **Le miroir hors site est une opération S3.** `mc mirror` d'un bucket vers un S3 externe est
   une commande ; d'un répertoire vers un S3, c'est un transfert complet à chaque fois.

## 2. Ce que MinIO n'est pas ici

**Ce n'est pas un stockage distribué.** Une seule instance, épinglée sur le nœud portant le label
`minio=true` (node3), avec un volume local. C'est un **SPOF assumé et documenté** (ADR-0008) :

- pendant que node3 est indisponible, **aucune sauvegarde ne peut être écrite ni relue** ; les
  jobs échouent, `BackupFailed` se déclenche et un ticket GLPI est ouvert ;
- la production, elle, n'est pas affectée : aucun service applicatif ne dépend de MinIO.

La vraie protection contre la perte de node3 n'est pas une seconde copie locale — trois VM de
6 Gio qui hébergent déjà trois bases ne peuvent pas raisonnablement porter un *erasure coding*
à trois voies — c'est le **miroir hors site horaire** (`offsite-mirror`, §9.1). La procédure de
reconstruction est dans [`docs/07-PRA.md`](../07-PRA.md).

## 3. Configuration du service (`stacks/backup.yml`)

| Élément | Valeur | Pourquoi |
|---|---|---|
| `command` | `server /data --console-address :9001` | API S3 sur 9000, console sur 9001 : deux ports, deux expositions différentes |
| `MINIO_ROOT_USER_FILE` / `..._PASSWORD_FILE` | `/run/secrets/dw_minio_root_*` | MinIO lit nativement la forme `_FILE` ; aucun *wrapper* d'entrée n'est nécessaire |
| `MINIO_PROMETHEUS_AUTH_TYPE` | `public` | voir §6 et l'ADR-0010 |
| `MINIO_UPDATE` | `off` | une image épinglée par digest ne doit pas se proposer de se mettre à jour |
| Réseaux | `data` + `edge` | `data` pour l'API S3 (interne, chiffré IPsec) ; `edge` **uniquement** pour que Traefik atteigne la console |
| `healthcheck` | `mc ready local` | sonde native de MinIO : elle ne répond `ready` qu'une fois les disques initialisés, contrairement à un simple test TCP |
| `update_config.order` | `stop-first` | un seul processus pour un seul répertoire de données : jamais deux en même temps |
| Placement | `node.labels.minio == true` | le volume est local ; sans contrainte, un redéploiement sur un autre nœud repartirait d'un dépôt vide |

### Ce qui est publié, et ce qui ne l'est pas

Seule la **console** (9001) est routée par Traefik, sur `minio.${DOMAIN}`, derrière
`admin-chain@file` (liste blanche `ADMIN_CIDR` + authentification *basic* + en-têtes de
sécurité). L'**API S3 (9000) n'est jamais publiée** : la publier reviendrait à exposer le dépôt
de sauvegarde sur le point d'entrée Internet, alors que rien hors du cluster n'a de raison d'y
écrire.

## 4. Buckets, comptes et politiques

Créés et appliqués par `scripts/minio-init.sh`, appelé par `deploy.sh` après le déploiement de la
stack `backup`.

| Bucket | Contenu | Versioning |
|---|---|---|
| `restic` | dépôt restic chiffré : SQL, Cassandra, fichiers GLPI, Prometheus, CrowdSec, état du cluster | **activé** |
| `es-snapshots` | *repository* S3 d'Elasticsearch (snapshots natifs pilotés par SLM) | désactivé |
| `mirror` | bucket de réception utilisé par `restore-all.sh --from offsite` lorsqu'il faut rapatrier depuis le S3 externe | désactivé |

**Pourquoi le versioning uniquement sur `restic`.** C'est une mesure anti-rançongiciel, pas une
politique de rétention : si les identifiants restic sont compromis et que le dépôt est effacé,
les objets deviennent des versions antérieures au lieu de disparaître. `restic forget --prune`
supprime normalement ; ce sont les versions antérieures et le miroir hors site qui restent
récupérables. Sur `es-snapshots`, Elasticsearch réécrit ses blobs d'index à chaque snapshot :
les versionner ferait croître le bucket sans limite, pour un mécanisme (les snapshots ES) qui
est déjà incrémental et versionné par nature.

### Comptes de service — une politique par consommateur

| Compte (valeur du secret) | Politique | Fichier | Droits |
|---|---|---|---|
| `dw_minio_restic_key` | `dw-restic` | `config/minio/policies/restic.json` | lecture/écriture/suppression sur `restic` **uniquement** |
| `dw_minio_es_key` | `dw-elasticsearch` | `config/minio/policies/elasticsearch.json` | lecture/écriture/suppression sur `es-snapshots` **uniquement** |
| `dw_minio_mirror_key` | `dw-mirror` | `config/minio/policies/mirror.json` | **lecture seule** sur `restic` et `es-snapshots` |

Chaque politique est un document IAM en deux instructions : une au niveau du
*bucket* (`ListBucket`, `GetBucketLocation`, et pour les comptes en écriture
`ListBucketMultipartUploads`) et une au niveau des objets (`GetObject`,
`PutObject`, `DeleteObject`, plus les opérations *multipart* — restic découpe
les gros paquets et ne peut pas les écrire sans elles). Le compte `mirror` n'a
que `ListBucket` et `GetObject`, sur les deux *buckets*.

Le compte `mirror` est en lecture seule par conception : un job de miroir qui peut écrire dans ce
qu'il recopie est un amplificateur de rançongiciel — une suppression malveillante côté source se
propagerait, et la source pourrait être écrasée depuis la destination.

L'isolation n'est pas seulement déclarée, elle est **testée** : `minio-init.sh` écrit, relit et
supprime un objet avec les identifiants `restic`, puis **vérifie que ce même compte ne peut pas
lister `es-snapshots`**. Une politique trop large (un ARN mal écrit, une politique non attachée)
serait sinon invisible jusqu'au jour où elle compte.

## 5. Initialisation — `scripts/minio-init.sh`

Idempotent par construction : chaque étape déclare un état voulu.

| # | Étape | Note |
|---|---|---|
| 1 | attendre l'API (`mc ready local`) | jusqu'à 120 s |
| 2 | créer les buckets (`mb --ignore-existing`) | forme idempotente |
| 3 | activer le versioning sur `restic` | |
| 4 | installer les politiques depuis `/etc/minio/policies/*.json` | `policy create` écrase : **le fichier dans git fait autorité** |
| 5 | créer les comptes et attacher leur politique | `user add` sur un compte existant met à jour sa clé secrète — exactement le comportement voulu après `init-secrets.sh --rotate` |
| 6 | **vérification** : écriture / lecture / suppression avec le compte `restic`, puis test d'isolation | |
| 7 | rappeler `scripts/es-init.sh` | il n'avait pas pu enregistrer le *repository* : MinIO n'existait pas encore quand `data` a été déployée |

Les politiques sont montées dans le conteneur en tant que **configs Swarm** (`config/minio/
policies/*.json`), hachées ensemble : modifier une politique change le hash, roule le service et
la ré-exécution du script la réapplique.

Toutes les commandes `mc` passent par `docker exec` dans le conteneur MinIO, avec l'alias fourni
par la variable d'environnement `MC_HOST_local` : les identifiants restent dans le conteneur (ils
y sont déjà, en tant que secrets Docker), rien n'est écrit dans un fichier de configuration `mc`,
et aucun mot de passe n'apparaît dans une ligne de commande visible par `ps`.

## 6. Métriques

Découverte par la découverte Swarm générique (labels `prometheus.job=minio`,
`prometheus.port=9000`, `prometheus.path=/minio/v2/metrics/cluster`), sans job Prometheus dédié.

`MINIO_PROMETHEUS_AUTH_TYPE=public` : MinIO n'accepte pas de jeton porteur arbitraire, seulement
un JWT dérivé des identifiants root, qui expire — et dont l'expiration ferait tomber la
supervision de MinIO en silence. Le raisonnement complet, les alternatives étudiées et le risque
résiduel sont dans [`ADR-0010`](../adr/0010-metriques-minio-public-reseau-interne.md). En
résumé : l'*endpoint* n'est joignable que depuis l'overlay `data`, qui est `internal` (aucune
route vers l'extérieur) et chiffré par IPsec, et n'est jamais routé par Traefik.

Alerte associée : **`MinIOCapacityLow`** (< 20 % libre pendant 30 min) — le dépôt qui se remplit
est le signal qui précède l'arrêt de **toutes** les sauvegardes, pas seulement d'une.

## 7. Exploitation

```bash
# Console (depuis un poste dans ADMIN_CIDR)
https://minio.${DOMAIN}

# Depuis un nœud : état, occupation, liste des comptes
docker exec $(docker ps -q -f label=com.docker.swarm.service.name=backup_minio) \
  sh -c 'export MC_HOST_l="http://$(cat /run/secrets/dw_minio_root_user):$(cat /run/secrets/dw_minio_root_password)@localhost:9000"; \
         mc admin info l; mc du l/restic l/es-snapshots; mc admin user list l'

# Réappliquer buckets, politiques et comptes (idempotent)
scripts/minio-init.sh
```

### Rotation des identifiants

1. `scripts/init-secrets.sh --rotate dw_minio_restic_secret` (crée un nouveau secret Docker) ;
2. mettre à jour les services qui le référencent, comme l'indique le script ;
3. `scripts/minio-init.sh` — `mc admin user add` met à jour la clé secrète du compte existant ;
4. vérifier avec `scripts/backup-now.sh backup-galera`.

Le mot de passe **restic** (`dw_restic_password`) est un cas à part : il ne peut pas être
« tourné ». C'est la clé de chiffrement AES-256 du dépôt. Le changer rend illisible tout ce qui a
déjà été sauvegardé. Sa rotation passe par la création d'un **nouveau dépôt** et la conservation
de l'ancien jusqu'à expiration de la rétention (`docs/08-exploitation.md`).

## 8. Alternative Garage

Prévue par le CDC §7.7 et l'ADR-0008 si l'image MinIO devait cesser d'être maintenue.
**Aucun script ne change** : même API S3, mêmes clés, même chemin restic
(`s3:http://minio:9000/restic`), même plugin `repository-s3` côté Elasticsearch.

Ce qu'il faudrait modifier :

1. `stacks/backup.yml` : l'image (`dxflrs/garage`), la commande et le `healthcheck` (Garage
   expose `/health` en HTTP plutôt que `mc ready`) ;
2. `scripts/minio-init.sh` : `mc admin user add` / `policy attach` deviennent
   `garage key new` / `garage bucket allow` — la partie buckets et versioning est identique ;
3. `docs/04-composants/versions.md` : la ligne d'image.

Le nom de service `minio` serait conservé tel quel, précisément pour que rien d'autre ne bouge :
il figure dans les scripts de sauvegarde, dans la définition du *repository* Elasticsearch et
dans les URL restic.

## 9. Points de vigilance

- **Le mot de passe restic et les clés MinIO doivent être hors du cluster.** Sans eux, aucune
  sauvegarde n'est restaurable — c'est rappelé par `init-secrets.sh` et dans le PRA.
- **MinIO plein = toutes les sauvegardes en échec.** Surveiller `MinIOCapacityLow` et vérifier
  que `restic-forget` s'exécute bien tous les jours à 06:00.
- **Ne jamais publier l'API S3 par Traefik**, même « temporairement pour un test ».
- **Le bucket `mirror` reste vide en fonctionnement normal** : il ne sert qu'au rapatriement.
  Un bucket `mirror` qui grossit signifie qu'une restauration hors site est en cours ou a été
  interrompue.

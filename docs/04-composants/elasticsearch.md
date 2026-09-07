# Elasticsearch — historisation des logs et des données métier

> Composant de la stack `data`. Couvre `config/elasticsearch/` (configuration, politiques ILM,
> templates d'index, SLM), les services `es-1/2/3`, `scripts/es-init.sh` et
> `scripts/gen-es-certs.sh`.
>
> Décision structurante : [ADR-0007 — Elasticsearch pour logs et données, pas de Loki ; HTTP interne sans TLS](../adr/0007-elasticsearch-logs-sans-loki.md).

## 1. Rôle dans la plateforme

Elasticsearch est le **moteur unique d'historisation** (exigences F2 et F3 du CDC) :

| Flux | Source | Data stream | Rétention |
|---|---|---|---|
| Logs de conteneurs | Fluent Bit (`tail` json-file) | `logs-docker` | 90 j |
| Logs du reverse proxy | Fluent Bit (journal d'accès Traefik) | `logs-traefik` | 90 j |
| Logs système | Fluent Bit (`systemd`) | `logs-system` | 90 j |
| Données métier | `demo-producer` (bulk) | `datalake-events` | 365 j |

Il est consulté de deux façons : **Kibana** pour l'exploration ad hoc, **Grafana** pour les
panneaux opérationnels corrélés aux métriques.

### Pourquoi pas Loki à côté

La pile Grafana classique ajoute Loki pour les logs. Ici, cela créerait **deux systèmes
d'historisation pour un même besoin** : deux moteurs à exploiter, deux rétentions à accorder, deux
sauvegardes. Elasticsearch était déjà imposé par l'énoncé pour l'historisation de données ; il
fait aussi très bien les logs, avec une recherche full-text que Loki n'a pas.

## 2. Topologie

| Propriété | Valeur |
|---|---|
| Services | `es-1`, `es-2`, `es-3` — un service Swarm par membre |
| Placement | contrainte `node.labels.es == N`, volume **local** `es_data_N` |
| Rôles | `master, data, ingest, remote_cluster_client` sur les trois |
| Quorum | 2 sur 3 |
| Heap | 1 Go (`full`) / 512 Mo (`lite`), `Xms == Xmx` |
| Limite mémoire | 2 Go, soit ~2× le heap |
| Réseau | `data` uniquement |

**Tous les nœuds portent tous les rôles.** Sur un cluster de trois, dédier un nœud au rôle master
laisserait deux nœuds de données et ferait perdre un tiers de la capacité sans gain de
disponibilité : le quorum est de 2 dans les deux cas.

**`Xms == Xmx`** : une JVM qui agrandit son heap fait une pause pour le faire, et sur un nœud de
données ces pauses ressemblent à une panne de nœud vue du cluster.

**Limite mémoire à ~2× le heap** : la JVM a aussi besoin de mémoire hors-tas pour les segments
Lucene mappés en mémoire, où se fait l'essentiel du travail de recherche.

## 3. Sécurité — TLS transport oui, TLS HTTP non

C'est le choix le plus discutable du projet, donc celui qui mérite le plus d'explications.

### Le transport est chiffré et authentifié, sans exception

```yaml
xpack.security.transport.ssl.enabled: true
xpack.security.transport.ssl.client_authentication: required
xpack.security.transport.ssl.verification_mode: certificate
```

C'est le canal qui transporte la réplication et l'état du cluster. C'est aussi la **frontière
d'authentification** : un nœud sans certificat signé par la CA du cluster ne peut tout simplement
pas rejoindre. Un attaquant qui atteindrait le réseau ne peut pas se présenter comme un quatrième
nœud et aspirer les données.

`verification_mode: certificate` et non `full` : `full` vérifie aussi que le nom d'hôte
correspond au certificat. Les SAN contiennent bien les noms de service, mais un service Swarm est
joint via une IP virtuelle dont la résolution inverse n'est pas le nom du service, ce qui fait
échouer `full` par intermittence. `certificate` exige toujours un certificat valide signé par la
CA des deux côtés — la propriété qui compte.

### L'API HTTP reste en clair — et pourquoi c'est défendable

```yaml
xpack.security.http.ssl.enabled: false
```

Quatre raisons cumulatives :

1. le réseau `data` est **`internal`** : pas de passerelle, aucune route vers ou depuis
   l'extérieur ;
2. il est **chiffré par IPsec** (`--opt encrypted`) : la confidentialité que TLS apporterait est
   déjà fournie une couche en dessous ;
3. **aucun port n'est publié** sur aucun hôte : l'API est injoignable hors de l'overlay ;
4. l'**authentification reste active** (`xpack.security.enabled: true`) : c'est
   « authentifié sur réseau chiffré », pas « ouvert ».

L'alternative — HTTPS — imposerait de distribuer et de faire tourner des certificats clients pour
Fluent Bit, Kibana, Grafana, l'exporter et chaque job de sauvegarde : **cinq modes de défaillance
supplémentaires pour une propriété déjà détenue**.

### Comment activer HTTPS si le contexte l'exige

```yaml
# config/elasticsearch/elasticsearch.yml
xpack.security.http.ssl.enabled: true
xpack.security.http.ssl.key: /usr/share/elasticsearch/config/certs/node.key
xpack.security.http.ssl.certificate: /usr/share/elasticsearch/config/certs/node.crt
xpack.security.http.ssl.certificate_authorities: [/usr/share/elasticsearch/config/certs/ca.crt]
```

Puis, côté clients : `elasticsearch.hosts` en `https://` dans `kibana.yml`, `tls On` +
`tls.ca_file` dans les trois `[OUTPUT]` de Fluent Bit, `https://` dans la datasource Grafana, et
le CA monté dans l'exporter et les jobs de sauvegarde. Le certificat de transport convient tel
quel : ses SAN contiennent déjà les noms de service.

## 4. `scripts/gen-es-certs.sh`

Génère une CA dédiée au transport et un certificat par nœud, chacun portant **son propre nom de
service dans le SAN** — c'est ce nom que les pairs résolvent
(`discovery.seed_hosts=es-1,es-2,es-3`).

Deux chemins de génération :

- **`elasticsearch-certutil`** depuis l'image officielle (`docker run --rm`), comme le prévoit le
  CDC §7.4. C'est l'outil de la distribution, il produit exactement ce qu'elle attend ;
- **repli openssl**, quand l'image n'est pas téléchargeable (poste isolé, registre bloqué). Le
  résultat est équivalent — une CA PEM et trois paires clé/certificat avec les bons EKU
  (`serverAuth` **et** `clientAuth` : sur le protocole transport, un nœud est à la fois serveur de
  ses pairs et client des leurs). Le script **annonce clairement** le chemin emprunté.

Il vérifie ensuite chaque certificat : validation contre la CA, **et présence du nom du nœud dans
le SAN**. Sans ce second contrôle, un certificat valide mais mal nommé produirait un nœud qui
échoue à rejoindre le cluster, avec un message d'erreur peu explicite.

> Note : dans l'environnement de développement, `docker.elastic.co` était refusé par la politique
> d'egress ; c'est le chemin openssl qui a été exercé et vérifié. Le chemin `certutil` est celui
> qui s'exécutera sur les VM.

## 5. `config/elasticsearch/elasticsearch.yml`

| Section | Réglage | Raison |
|---|---|---|
| Découverte | `discovery.seed_hosts: es-1,es-2,es-3` | noms de service Swarm : stables à travers les replanifications, contrairement à une IP de conteneur |
| | `cluster.initial_master_nodes` | **bootstrap uniquement** : Elasticsearch l'ignore une fois le cluster formé. Il doit lister exactement les trois noms, sinon un nœud redémarré seul pourrait former un second cluster |
| Réseau | `network.host: 0.0.0.0` + `network.publish_host: ${ES_NODE_NAME}` | écouter partout dans le conteneur, mais **publier le nom de service** : l'adresse annoncée aux pairs doit leur être routable |
| Mémoire | `bootstrap.memory_lock: true` | un heap JVM qui swappe provoque des pauses GC de plusieurs secondes, indiscernables d'une panne de nœud. Exige `ulimits.memlock: -1` (posé dans la stack) et la limite hôte du rôle Ansible `common` |
| Disque | watermarks à **80/85/90 %** au lieu de 85/90/95 | sur un nœud de 40 Go partagé avec Cassandra et MariaDB, atteindre 90 % met tous les index en lecture seule et est pénible à défaire. L'alerte `ESDiskWatermark` se déclenche à 85 %, avant que les écritures ne soient refusées |
| Reprise | `node_concurrent_recoveries: 2`, `indices.recovery.max_bytes_per_sec: 80mb` | plafonné pour qu'une reprise ne sature pas l'overlay et n'affame pas Galera et Cassandra sur les mêmes 3 VM |
| Sûreté | `action.destructive_requires_name: true` | refuse `DELETE /*` et `DELETE /_all`. La protection la moins chère contre une perte totale accidentelle |
| | `action.auto_create_index` restreint | une faute de frappe dans un client ne doit pas créer un index sans mapping |

Le **délai avant réallocation** des shards d'un nœud disparu est un réglage **d'index**, pas de
nœud : `index.unassigned.node_left.delayed_timeout: 5m`, posé dans les templates. Le défaut d'une
minute est plus court qu'une replanification Swarm — un redémarrage de nœud déclencherait une
reconstruction complète des shards, pour rien.

## 6. Politiques ILM

### `dockerwarts-logs` (90 jours)

| Phase | Déclenchement | Actions |
|---|---|---|
| hot | immédiat | rollover à **10 Go de shard primaire** OU **1 jour** |
| warm | 7 j | `forcemerge` à 1 segment, `number_of_replicas: 1` **conservé** |
| delete | 90 j | suppression |

- **Les deux conditions de rollover** parce que les deux modes d'échec diffèrent : une salve
  d'erreurs atteint 10 Go en quelques heures, tandis qu'une nuit calme laisserait sinon un index
  ouvert pendant des semaines.
- **`forcemerge` à 1 segment** en warm : un log n'est jamais mis à jour après son ingestion, donc
  un segment unique est optimal pour la recherche et divise l'empreinte disque.
- **La réplique est conservée en warm.** C'est un choix explicite : la supprimer économiserait de
  la place mais violerait N2 — perdre un nœud perdrait les logs tièdes.

### `dockerwarts-datalake` (365 jours)

Pas de phase warm : c'est la copie analytique du datalake, interrogée sur des plages de temps
arbitraires par les dashboards, il n'y a donc pas de « queue froide » à déprioriser. Un
`forcemerge` se battrait aussi contre l'ingestion continue de `demo-producer`.

## 7. Templates d'index

Un **component template** partagé (`dockerwarts-logs-common`) plus un template d'index par flux.
L'extraction en composant n'est pas cosmétique : un changement de mapping se fait une fois au lieu
de trois et ne peut pas diverger entre flux — ce qui est exactement ce qui casse une requête de
logs transversale.

| Réglage | Valeur | Raison |
|---|---|---|
| `number_of_shards` | 1 | un shard unique évite le surcoût fixe par shard sur de petits index quotidiens |
| `number_of_replicas` | **1**, pas 2 | 50 % de disque en plus pour aucun gain : avec 3 nœuds, 1 réplique survit déjà à la perte de n'importe lequel |
| `codec` | `best_compression` (DEFLATE) | les logs se compressent très bien et sont lus bien moins souvent qu'écrits : ~15-20 % de disque en moins |
| `refresh_interval` | 10 s (logs), 5 s (datalake) | personne n'a besoin d'une visibilité des logs à la seconde ; 10× moins de rafraîchissements, c'est beaucoup moins de churn de segments et de CPU |
| `dynamic` (logs) | **`false`** | un champ non mappé est **conservé dans `_source` et visible dans Kibana**, mais n'est pas indexé. Cela bloque l'explosion de mapping d'une application bavarde sans jamais perdre de donnée |
| `dynamic` (datalake) | **`strict`** | ce flux a **un** producteur au schéma fixe. Un document portant un champ inattendu est un bug de `demo-producer` et doit être rejeté bruyamment |

Deux typages méritent d'être signalés :

- `ClientHost` en **`ip`** et non `keyword` : cela autorise les requêtes par plage CIDR pendant un
  incident (`ClientHost: "203.0.113.0/24"`), ce qu'un `keyword` ne permet pas ;
- `temperature`/`humidity` en **`float`** et non `double` : la précision des capteurs est de
  ~0,1 °C, sept chiffres significatifs suffisent largement et l'index est deux fois plus petit.

## 8. Snapshots — repository S3 et SLM

Sauvegarde par **snapshots natifs** et non par restic sur les volumes (ADR-0008) : un snapshot est
cohérent par construction (il capture des segments Lucene validés), incrémental au niveau du
segment, et restaurable index par index. Copier le répertoire de données d'un nœud vivant
produirait une archive corrompue et non restaurable.

Les identifiants S3 vont dans le **keystore** d'Elasticsearch, pas dans la définition du
repository : une définition de repository est lisible par l'API pour quiconque a `monitor`, une
entrée de keystore ne l'est pas.

Politique `daily-snapshots` :

| Réglage | Valeur | Raison |
|---|---|---|
| `schedule` | `0 0 1 * * ?` (01:00 UTC) | avant `backup-galera` (02:00) : les deux ne se disputent jamais la bande passante MinIO |
| `include_global_state` | **`true`** | ramène les politiques ILM, les templates et le domaine de sécurité avec les données. Sans lui, une restauration complète réhydraterait des documents dans un cluster sans cycle de vie |
| `partial` | **`false`** | un snapshot auquel il manque un shard n'est pas une sauvegarde. Mieux vaut un échec bruyant (capté par `ESSnapshotFailed`) qu'une archive silencieusement non restaurable |
| `min_count` | **7** | 7 snapshots conservés **quel que soit leur âge** : si les snapshots s'arrêtent pendant un mois, `expire_after` seul supprimerait le dernier bon juste au moment où on en a besoin |

`scripts/es-init.sh` appelle `_snapshot/minio/_verify` après l'enregistrement : cela écrit **et**
relit un blob de test. Un repository qui s'enregistre mais où l'on ne peut pas écrire est
l'échec de sauvegarde silencieux classique.

## 9. `scripts/es-init.sh`

Idempotent par construction : chaque appel est un `PUT` d'un état désiré, donc une réexécution
converge au lieu d'échouer.

Neuf étapes : santé du cluster → mots de passe intégrés → rôles et utilisateurs → ILM → templates
→ data streams → repository + SLM → data views Kibana → vérification.

### Rôles : le principe du moindre privilège, concrètement

| Rôle | Privilèges | Ce que cela empêche |
|---|---|---|
| `dw_logs_writer` (fluentbit) | `create_doc`, `create_index` sur `logs-*` — **aucune lecture** | un collecteur de logs compromis écrit des logs ; il ne lit rien et ne touche pas au datalake |
| `dw_reader` (grafana) | `read` sur `logs-*` et `datalake-*` | une datasource compromise ne peut rien modifier |
| `dw_datalake_writer` | écriture sur `datalake-events*` uniquement | |
| `dw_exporter` | `monitor` — **aucun accès aux documents** | l'exporter de métriques ne peut pas lire les données |

### Les data streams sont créés explicitement

`action.auto_create_index` est restreint dans `elasticsearch.yml`, donc les flux doivent exister
avant toute écriture. C'est volontaire : une faute de frappe dans un client ne doit pas créer un
index sans mapping qui échapperait ensuite à l'ILM.

### L'étape 7 dépend de MinIO, déployé plus tard

`scripts/es-init.sh` s'exécute après la stack `data`, MinIO arrive avec `backup`. Le script
**saute proprement** l'enregistrement du repository avec un message explicite, et
`scripts/minio-init.sh` le rappelle pour finir le travail. Ce n'est pas ignoré, c'est ordonnancé.

### Vérification finale

Le script ne se contente pas de vérifier que les politiques existent : il contrôle que
`index.lifecycle.name` est bien **attaché** à l'index sous-jacent de `logs-docker`. Une politique
qui existe mais n'est pas appliquée conserverait les données indéfiniment, sans rien signaler.

## 9 bis. Les fichiers de configuration, un par un

Tous appliqués par `scripts/es-init.sh` : ce sont des **états voulus** poussés
par l'API, jamais des fichiers montés dans le conteneur. La source de vérité est
git ; ré-exécuter le script réapplique le contenu du dépôt.

| Fichier | Rôle | Section |
|---|---|---|
| `config/elasticsearch/elasticsearch.yml` | configuration du nœud : découverte, TLS transport, mémoire | §5 |
| `config/elasticsearch/ilm/dockerwarts-logs.json` | cycle de vie des logs : rollover puis suppression à 90 j | §6 |
| `config/elasticsearch/ilm/dockerwarts-datalake.json` | cycle de vie du datalake : rétention 365 j | §6 |
| `config/elasticsearch/templates/logs-common.json` | *component template* : les champs partagés par tous les logs (`@timestamp`, `host`, `container`) — définis une fois, hérités par les trois autres |
| `config/elasticsearch/templates/logs-docker.json` | template d'index des logs de conteneurs | §7 |
| `config/elasticsearch/templates/logs-traefik.json` | template d'index des logs d'accès Traefik | §7 |
| `config/elasticsearch/templates/logs-system.json` | template d'index des logs système du nœud | §7 |
| `config/elasticsearch/templates/datalake-events.json` | template du data stream `datalake-events`, `dynamic: strict` | §7 |
| `config/elasticsearch/slm.json` | politique de snapshots `daily-snapshots` vers MinIO | §8 |

Chacun porte un bloc `_meta` ou `_comment` qui explique ses propres choix, et
qu'Elasticsearch conserve : la justification voyage avec la politique, y compris
pour qui la lit depuis l'API et n'a pas le dépôt sous les yeux.

## 10. Supervision

| Élément | Détail |
|---|---|
| Exporter | `prometheuscommunity/elasticsearch-exporter`, compte `exporter` (rôle `monitor`) |
| Métriques clés | `elasticsearch_cluster_health_status`, `_active_shards`, `_unassigned_shards`, `elasticsearch_jvm_memory_used_bytes`, `elasticsearch_filesystem_data_available_bytes`, `elasticsearch_indices_indexing_index_total` |
| Alertes | `ESClusterRed` (1 min, critical), `ESClusterYellow` (**> 10 min**, warning), `ESDiskWatermark` (> 85 %, warning), `ESJVMHeapHigh` (warning), `ESSnapshotFailed` (warning) |
| Dashboard | « Elasticsearch » : santé, shards, heap JVM, indexation/s, latence de recherche, disque |

Le seuil de **10 minutes sur `ESClusterYellow`** est délibéré : `yellow` est l'état **normal et
transitoire** pendant une replanification, le temps que les répliques se réallouent. Alerter
immédiatement produirait un ticket à chaque mise à jour progressive.

## 11. Sauvegarde

| Élément | Sauvegardé | Méthode |
|---|---|---|
| Index et data streams | **oui** | SLM natif `daily-snapshots` vers MinIO, 01:00, rétention 30 j / min 7 / max 50 |
| Volumes `es_data_N` | **non** | justifié : les snapshots sont cohérents, incrémentaux et restaurables ; une copie de volume vivant ne l'est pas |
| Objets sauvegardés Kibana | non | reprovisionnés par `es-init.sh` |

Restauration : `scripts/restore/restore-es.sh`, avec `--rename` (restauration en parallèle dans
`restored-*` puis bascule d'alias — la voie sûre) ou en place après fermeture des index.

## 12. Points d'attention

| Point | Détail |
|---|---|
| Digests non épinglés | `docker.elastic.co` était inaccessible depuis l'environnement de développement. Les deux images sont dans `config/unpinned-images.txt` avec la commande exacte pour clore l'exception |
| `vm.max_map_count` | posé par le rôle Ansible `common`. Sans lui, Elasticsearch refuse de démarrer, avec un message peu clair |
| `memory_lock` | exige `ulimits.memlock: -1` **et** la limite hôte. Si l'un manque, le nœud démarre mais log un avertissement et peut swapper |
| `cluster.initial_master_nodes` | inoffensif une fois le cluster formé, mais doit lister les **trois** noms |
| `yellow` transitoire | normal pendant une replanification. Ne pas abaisser le seuil de 10 min de l'alerte |
| HTTP en clair | choix documenté (§3), pas un oubli. Le contexte qui le rend acceptable — réseau `internal` + IPsec + aucun port publié — doit être vérifié avant toute réutilisation ailleurs |

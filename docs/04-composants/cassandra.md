# Cassandra — datalake distribué

> Composant de la stack `data`. Couvre `images/cassandra/Dockerfile`,
> `config/cassandra/{jmx-exporter.yml,init.cql}`, les services `cassandra-1/2/3` et
> `scripts/cassandra-init.sh`.

## 1. Rôle dans la plateforme

Cassandra est le **datalake** de l'énoncé : le magasin d'événements capable d'absorber un volume
d'écritures élevé et continu, réparti sur trois nœuds, sans point unique de défaillance.

Il reçoit les événements produits par `demo-producer` (CDC §7.8) : relevés de capteurs
`{site, sensor_id, ts, temperature, humidity}`, écrits en `LOCAL_QUORUM`.

### Cassandra *et* Elasticsearch : pourquoi les deux

Les mêmes événements sont écrits dans les deux moteurs. Ce n'est pas une redondance, c'est une
**répartition des rôles** (ADR-0007) :

| Question | Moteur | Pourquoi |
|---|---|---|
| « les 100 derniers relevés du capteur A du site B, aujourd'hui » | **Cassandra** | c'est exactement sa clé de partition : la réponse est un accès disque séquentiel dans une seule partition |
| « température moyenne par site sur 30 jours » | **Elasticsearch** | agrégation sur des millions de documents, impossible en CQL sans scan complet |
| « tous les capteurs dont l'humidité a dépassé 80 % » | **Elasticsearch** | recherche sur une valeur non clé — Cassandra devrait tout parcourir |
| écriture soutenue, durable, sans index à maintenir | **Cassandra** | écriture en commit log + memtable, aucun coût d'indexation |

Cassandra est la **source de vérité durable** (RF=3, TTL 90 j) ; Elasticsearch est la **copie
analytique**.

## 2. Topologie

| Propriété | Valeur |
|---|---|
| Services | `cassandra-1`, `cassandra-2`, `cassandra-3` — un service Swarm par membre |
| Placement | contrainte `node.labels.cassandra == N`, volume **local** `cassandra_data_N` |
| Seeds | `cassandra-1,cassandra-2` — **jamais les trois** (voir §3) |
| Snitch | `GossipingPropertyFileSnitch`, `dc1`, `rack1/2/3` |
| Réplication | `NetworkTopologyStrategy {'dc1': 3}`, RF=3 |
| Cohérence | `LOCAL_QUORUM` (2 sur 3) en lecture **et** en écriture |
| Heap | 1 Go (profil `full`) / 768 Mo (`lite`), via `${CASSANDRA_HEAP}` |
| Réseau | `data` uniquement — aucun port publié |

### RF=3 + LOCAL_QUORUM = RPO 0

Avec R + W > N (2 + 2 > 3), toute lecture au quorum voit forcément la dernière écriture validée
au quorum. Une écriture acquittée par deux nœuds survit à la perte de n'importe lequel : c'est
l'exigence N2 du CDC.

### Pourquoi seulement deux seeds

Un nœud *seed* ne passe pas par le chemin de bootstrap normal : il rejoint l'anneau directement.
Déclarer les trois nœuds comme seeds est un moyen documenté de se retrouver avec un anneau
incohérent, où deux nœuds revendiquent les mêmes plages de jetons. Deux seeds suffisent pour la
tolérance de panne au démarrage.

### Pourquoi `GossipingPropertyFileSnitch` et non `SimpleSnitch`

`SimpleSnitch` ignore les racks et les datacentres, et impose `SimpleStrategy`. Migrer ensuite
vers `NetworkTopologyStrategy` demande une reconstruction complète des réplicas. Partir en
gossiping ne coûte rien aujourd'hui et fait d'un second datacentre (la piste d'évolution du PRA)
un simple `ALTER KEYSPACE`.

Les trois racks (`rack1/2/3`) traduisent le fait que les trois nœuds sont trois machines
distinctes : Cassandra place alors les trois réplicas sur trois racks différents, ce qui est
exactement ce que l'on veut.

## 3. `images/cassandra/Dockerfile` — l'image maison

L'unique raison d'exister de cette image : **embarquer l'agent JMX Prometheus dans la JVM**.

| Alternative | Problème |
|---|---|
| conteneur `jmx_exporter` séparé | il faudrait ouvrir le port JMX sur le réseau pour chaque nœud, avec des identifiants — trois services de plus et une surface d'attaque nouvelle |
| `cassandra_exporter` (tiers) | suit les versions de Cassandra avec retard |
| **javaagent in-JVM** | tourne **dans** le processus qu'il mesure, aucun JMX réseau, expose du HTTP simple sur `:7070` |

Construction en deux étapes :

- **étape `fetch`** : télécharge le JAR depuis Maven Central et **vérifie sa somme SHA-256**. Ce
  JAR s'exécute à l'intérieur de la JVM de la base de données, avec un accès complet à celle-ci :
  un artefact non vérifié serait une porte d'entrée totale. `curl` et les outils de vérification
  ne survivent pas à cette étape.
- **étape finale** : copie le JAR en `0444`, conserve l'utilisateur `cassandra` (uid 999) de
  l'image amont — le CDC §6.4 demande un utilisateur non root « quand l'image le permet », et
  celle-ci le fait déjà correctement.

La version **1.0.1** et son empreinte ont été obtenues en téléchargeant l'artefact et en le
confrontant au SHA-1 publié par Maven Central à côté de lui
(`f9c53eb0aa1828c3c9cd7647238563e43a4ed68c`) — jamais recopiées d'une source tierce. Pour monter
de version, refaire cette vérification ; ne jamais deviner la valeur.

La configuration de l'agent n'est **pas** intégrée à l'image : elle est montée en `config` Swarm,
pour qu'ajuster le jeu de métriques n'impose pas une reconstruction.

## 4. `config/cassandra/jmx-exporter.yml`

Cassandra publie **des dizaines de milliers** de MBeans — un jeu par table, par keyspace, par pool
de threads. Tout exporter produirait une charge utile `/metrics` de plusieurs mégaoctets, un
scrape de plusieurs secondes, et une base Prometheus dominée par des séries que personne ne
regarde. Pire : le scrape JMX deviendrait lui-même une charge mesurable sur la base.

D'où une **liste blanche explicite**, structurée en neuf blocs :

| # | Bloc | Ce qu'il alimente |
|---|---|---|
| 1 | `FailureDetector` up/down endpoints | alerte `CassandraNodeDown`, panneau « nœuds UN/DN » |
| 2 | `ClientRequest` latence + timeouts/unavailables/failures | latences R/W du dashboard. **Un `Unavailables` non nul signifie que le niveau de cohérence n'a pas pu être satisfait** — c'est le signal le plus important de tous |
| 3 | `Compaction` PendingTasks | alerte `CassandraPendingCompactions` |
| 4 | `Storage` Load, TotalHints | alerte `CassandraDiskUsage`. **`TotalHints` qui monte est le signal le plus précoce** qu'un pair est injoignable et qu'un `repair` sera nécessaire |
| 5 | `ThreadPools` pending/active/blocked | là où la saturation apparaît en premier |
| 6 | métriques **par keyspace** (et non par table) | garde la cardinalité plate |
| 7 | `DroppedMessage` | symptôme direct de surcharge |
| 8 | JVM heap + GC | les problèmes de performance Cassandra sont très souvent des problèmes de GC |
| 9 | **`pattern: ".*"` sans `name`** | **règle finale obligatoire** : elle jette tout le reste |

Le bloc 9 doit rester **en dernier** : les règles sont évaluées dans l'ordre et la première qui
correspond gagne. Sans lui, l'exporter reviendrait à son comportement par défaut et publierait
tous les MBeans restants — exactement ce que ce fichier existe pour empêcher.

## 5. `config/cassandra/init.cql` — le modèle de données

### Keyspace

```cql
CREATE KEYSPACE datalake WITH replication =
  {'class': 'NetworkTopologyStrategy', 'dc1': 3} AND durable_writes = true;
```

`durable_writes = true` : le commit log est écrit avant l'acquittement. Le désactiver n'a de sens
que pour un keyspace reconstructible depuis ailleurs — ce qu'un datalake n'est pas.

### Table `events` — la décision la plus lourde de conséquences

```cql
PRIMARY KEY ((site, sensor_id, day), ts)
WITH CLUSTERING ORDER BY (ts DESC)
```

| Choix | Raison |
|---|---|
| partitionner sur `(site, sensor_id, day)` | **borne la taille de partition**. Au rythme de démo (20 év/s sur 50 capteurs), un capteur produit ~35 000 lignes par jour, soit ~3 Mo — largement dans les ~100 Mo que Cassandra gère bien. Partitionner sur `(site, sensor_id)` seul grossirait sans limite jusqu'à rendre la partition illisible |
| inclure `day` dans la clé de **partition** et non de clustering | c'est ce qui **répartit les écritures successives sur l'anneau** au lieu de marteler un seul jeu de réplicas : la « partition chaude » classique des séries temporelles |
| `ts DESC` | toutes les requêtes des dashboards sont « les N dernières minutes » : la réponse est en tête de partition, Cassandra ne lit jamais au-delà |

Le prix est **explicite et assumé** : une requête doit toujours nommer `site`, `sensor_id` et
`day`. L'analytique transversale va à Elasticsearch, qui est indexé pour cela.

### TTL, tombstones et compaction — le trio qui se tient

```cql
default_time_to_live = 7776000        -- 90 jours
gc_grace_seconds     = 259200         -- 3 jours
compaction = {'class': 'TimeWindowCompactionStrategy',
              'compaction_window_unit': 'DAYS', 'compaction_window_size': 1}
```

- **TTL de 90 jours** aligné sur la politique ILM `dockerwarts-logs` : les deux magasins
  vieillissent ensemble, et une requête de corrélation ne trouve jamais un côté vide. Exprimé en
  TTL plutôt qu'en job de purge : Cassandra n'a pas de `DELETE` efficace, et une suppression de
  masse créerait des tombstones qui dégradent les lectures bien plus que les données elles-mêmes.
- **`gc_grace_seconds` à 3 jours** (défaut : 10). C'est la fenêtre pendant laquelle les tombstones
  sont conservées pour qu'un nœud absent ne puisse pas « ressusciter » des données supprimées.
  Elle **doit** être plus longue que l'intervalle entre deux `repair` — le job hebdomadaire tourne
  tous les 7 jours, donc 3 jours serait **dangereux avec des DELETE**. C'est sûr **ici** parce que
  les lignes expirent par TTL, et l'expiration par TTL ne dépend pas du cycle de repair.
  **Si un jour un DELETE est ajouté au modèle, remonter à 864000 (10 jours).** C'est écrit dans le
  fichier lui-même.
- **TWCS** au lieu du SizeTiered par défaut : avec des séries temporelles et un TTL, TWCS regroupe
  chaque journée dans sa propre SSTable, qui peut être **supprimée en entier** à l'expiration —
  aucun travail de compaction, aucune tombstone, aucune amplification de lecture. SizeTiered
  mélangerait indéfiniment ancien et récent et ne pourrait jamais rien libérer à bon compte.

### Table `events_by_site`

Dénormalisation assumée : un compteur par site et par minute, écrit en même temps que l'événement
brut. Elle répond au panneau « événements/s par site » sans parcourir les partitions brutes.

C'est la façon Cassandra de faire : pas de jointure, pas d'index secondaire utile, donc **une
seconde table pour un second motif de requête**. Une colonne `counter` ne peut pas porter de TTL
(restriction Cassandra), d'où une purge par le job hebdomadaire — la table est minuscule
(1440 lignes par site et par jour).

## 6. `scripts/cassandra-init.sh`

Idempotent, exécuté après chaque déploiement de `data`.

### L'étape que tout le monde oublie : le superutilisateur par défaut

Une Cassandra fraîche avec `PasswordAuthenticator` embarque un superutilisateur
`cassandra`/`cassandra`. Il **ne peut pas être supprimé** tant qu'il est le seul superutilisateur.
La séquence correcte est donc :

1. se connecter avec lui ;
2. créer un **nouveau** superutilisateur (`dwadmin`) ;
3. se connecter avec le nouveau ;
4. **rétrograder et verrouiller** le compte par défaut (`SUPERUSER = false AND LOGIN = false`).

Laisser `cassandra/cassandra` actif, c'est une compromission totale de la base pour quiconque
atteint le réseau `data`.

### L'autre étape critique : `system_auth` en RF=3

Le keyspace `system_auth` — celui qui contient les comptes — est créé avec **RF=1** par défaut.
Si le nœud qui le détient tombe, **plus personne ne peut s'authentifier**, y compris le script
lui-même. Le passer à RF=3 est obligatoire sur un cluster à 3 nœuds, et c'est fait **avant**
toute autre chose, suivi d'un `nodetool repair` qui propage effectivement les réplicas
supplémentaires (un `ALTER` seul ne copie rien).

### Comptes applicatifs

| Compte | Droits |
|---|---|
| `dwadmin` | superutilisateur (administration) |
| `datalake_app` | `SELECT, MODIFY` sur le keyspace `datalake` uniquement |
| `backup` | `SELECT` uniquement — `nodetool snapshot` passe par JMX avec ses propres identifiants |

### Vérification finale

Le script ne se contente pas de vérifier que le schéma existe : il fait un **aller-retour
écriture/lecture réel en `LOCAL_QUORUM`** (avec un TTL de 60 s pour ne rien laisser derrière).
C'est la seule façon de prouver que le niveau de cohérence est réellement satisfaisable — une
vérification de schéma passerait sur un cluster à deux nœuds sur trois.

## 7. Authentification JMX

`nodetool` doit être joignable à distance par les jobs de sauvegarde (`nodetool snapshot` sur un
autre nœud). L'authentification JMX est donc activée :

```
-Dcom.sun.management.jmxremote.authenticate=true
-Dcom.sun.management.jmxremote.password.file=/run/secrets/dw_cassandra_jmx_password
-Dcom.sun.management.jmxremote.access.file=/run/secrets/dw_cassandra_jmx_access
```

**La JVM refuse de démarrer si le fichier de mots de passe est lisible par le groupe ou par les
autres.** D'où `mode: 256` (0400) sur les deux secrets dans `stacks/data.yml` : ce n'est pas une
préférence, c'est une condition de démarrage.

Le port JMX (7199) n'est accessible que sur le réseau `data`, `internal` et chiffré.

## 8. Supervision

| Élément | Détail |
|---|---|
| Endpoint | `:7070/metrics`, labels `prometheus.job=cassandra`, `prometheus.port=7070` |
| Alertes | `CassandraNodeDown` (cible absente 2 min, critical), `CassandraPendingCompactions` (> 100 pendant 15 min, warning), `CassandraDiskUsage` (warning) |
| Dashboard | « Cassandra » : nœuds UN/DN, latences R/W, compactions en attente, hints, disque, GC |

Le healthcheck (`nodetool status | grep UN`) interroge la vue **de ce nœud** sur l'anneau : c'est
la bonne question, parce qu'un nœud isolé du reste se voit lui-même en `UN` mais voit les autres
en `DN`, et le dashboard le montre immédiatement.

## 9. Sauvegarde

| Élément | Sauvegardé | Méthode |
|---|---|---|
| Keyspace `datalake` | **oui** | `backup-cassandra-N`, 03:00, `nodetool snapshot` (JMX) → `cqlsh DESCRIBE KEYSPACE` → `restic backup` du répertoire `snapshots/daily` → `nodetool clearsnapshot` |
| Volume complet | non | un snapshot est un ensemble de **liens durs** vers des SSTables immuables : c'est cohérent par construction et quasi instantané. Copier un répertoire de données vivant produirait une archive incohérente |

Le schéma est sauvegardé **avec** les données (`DESCRIBE KEYSPACE`) : sans lui, les SSTables sont
illisibles. C'est l'erreur classique des sauvegardes Cassandra.

Restauration : `scripts/restore/restore-cassandra.sh`, avec deux variantes — `sstableloader`
(topologie indépendante, la voie sûre) et copie + `nodetool refresh` (même topologie, plus rapide).

Maintenance : `nodetool repair -pr` hebdomadaire (`maint-cassandra-repair`, dimanche 05:00). Le
`-pr` (primary range) évite de réparer trois fois les mêmes données quand le job passe sur les
trois nœuds.

## 10. Points d'attention

| Point | Détail |
|---|---|
| `gc_grace_seconds = 3 j` | sûr **uniquement** parce que le modèle n'utilise que des TTL. Ajouter un `DELETE` impose de remonter à 10 jours, sinon des données supprimées peuvent réapparaître |
| Démarrage lent | 2 à 4 minutes. `start_period: 240s` sur le healthcheck n'est pas de la marge, c'est le temps réel |
| `stop_grace_period: 120s` | Cassandra vide ses memtables sur SIGTERM. La tuer impose de rejouer le commit log au démarrage — lent, et sur un disque plein, susceptible d'échouer |
| Remplacement de nœud | ne **jamais** laisser un nœud de remplacement bootstrapper normalement : il deviendrait un 4ᵉ membre. Utiliser `-Dcassandra.replace_address_first_boot=<ancienne adresse>` (voir `node-replace.yml`) |
| Mode 0400 des secrets JMX | condition de démarrage de la JVM, pas un choix esthétique |
| Requêtes hors clé de partition | elles échoueront ou exigeront `ALLOW FILTERING`. C'est **voulu** : ces requêtes vont à Elasticsearch |

# demo-producer — charge de fond du datalake

> **Rôle** : générer en continu des événements capteurs vers Cassandra et
> Elasticsearch, pour que les tableaux de bord aient quelque chose à montrer et,
> surtout, pour que les promesses de haute disponibilité deviennent **mesurables**.
> **Références** : CDC §7.8, §8.2 n°5 ; ADR-0007 (deux magasins complémentaires).
> **Fichiers** : `images/demo-producer/`, `stacks/demo.yml`.

---

## 1. Pourquoi ce service existe

Deux raisons, et la seconde est la vraie.

**Les tableaux de bord ont besoin de données.** Un Grafana vide ne prouve rien
d'un datalake, et une capture d'écran d'une ligne plate à zéro n'est pas une
démonstration que Cassandra et Elasticsearch fonctionnent.

**Les affirmations de HA deviennent des mesures.** Le CDC §8.2 n°5 demande une
charge continue pendant la campagne chaos, avec un compteur d'erreurs qui doit
rester à zéro. Ce compteur est l'affirmation la plus nette que la plateforme
puisse produire : *la production ne s'est pas interrompue pendant qu'on tuait un
nœud*. Un test de fumée vert après coup dit que la plateforme s'est rétablie ;
un zéro ici dit qu'elle n'est jamais tombée.

C'est pour cela que `make chaos` avertit explicitement quand `demo-producer`
n'est pas déployé : le critère n'est alors pas « validé », il est **non mesuré**,
et le rapport le dit.

## 2. Ce qu'il écrit

`{site, sensor_id, ts, temperature, humidity}` pour `SENSORS` capteurs (50 par
défaut) répartis sur trois sites, à `RATE` événements/s (20 par défaut), dans
**les deux** magasins — parce qu'ils répondent à des questions différentes et
sont complémentaires par conception (ADR-0007) :

| Destination | Contenu | Ce qu'elle sert |
|---|---|---|
| `datalake.events` (Cassandra) | l'événement brut, clé `(site, sensor_id, day)` | la série temporelle d'**un** capteur sur **un** jour, lue en millisecondes |
| `datalake.events_by_site` (Cassandra) | un compteur par site et par minute | le panneau « événements/s par site », sans scanner les partitions brutes |
| `datalake-events` (Elasticsearch) | le même événement, indexé | l'analytique **transverse** (tous capteurs, toutes dates) que la clé de partition Cassandra refuse délibérément de servir |

### Les valeurs dérivent, elles ne sautent pas

Chaque capteur effectue une **marche aléatoire bornée** : la valeur bouge un peu
à chaque pas, et un rappel vers la ligne de base du site (15 % de l'écart)
l'empêche de partir sur des journées de fonctionnement.

Ce n'est pas de la coquetterie. Un bruit indépendant redessiné à chaque seconde
donnerait une moyenne parfaitement plate — tous les panneaux d'agrégat
deviendraient des lignes droites, et un panneau d'anomalie ne montrerait jamais
rien. La dérive est ce qui rend un graphe des dernières heures lisible comme une
*mesure*.

La graine est **fixe** (`random.Random(20260907)`) : deux exécutions de la
campagne produisent des graphes comparables, et une régression dans les données
est visible au lieu d'être noyée dans de l'aléatoire frais.

## 3. Décisions d'écriture qui comptent

### Cassandra : exécution concurrente, pas de `BATCH`

Le CDC parle d'« écriture en batch ». La forme retenue est
`execute_concurrent_with_args`, **pas** un `BatchStatement` CQL, et la différence
est importante :

- un `BATCH` CQL couvrant plusieurs partitions est un **anti-patron** : il force
  un seul coordinateur à diffuser vers chaque jeu de réplicas, et la latence du
  lot devient celle du plus lent ;
- ces lignes appartiennent à autant de partitions qu'il y a de capteurs ;
- l'exécution concurrente du driver est **token-aware** : chaque requête part
  directement vers un réplica de sa partition. Le coordinateur *est* un réplica,
  et un saut réseau disparaît de chaque écriture.

### `is_idempotent = True` sur l'insertion — et pas sur le compteur

C'est ce qui autorise le driver à **rejouer** une écriture sur un autre
coordinateur après un dépassement de délai. Sans cela, une écriture qui a expiré
est simplement perdue — et une perte de nœud produit exactement ces
dépassements, qui apparaîtraient comme des erreurs dans le compteur que ce
service existe pour maintenir à zéro. C'est sûr ici parce que la clé primaire
détermine entièrement la ligne : rejouer l'insertion réécrit la même valeur.

L'`UPDATE` du compteur `events_by_site`, lui, n'est **pas** marqué idempotent, et
délibérément : un incrément rejoué est un compteur incrémenté deux fois.

### `LOCAL_QUORUM`

2 réplicas sur 3 : survit à la perte d'un nœud — précisément le scénario de la
campagne chaos — tout en garantissant qu'une lecture en `LOCAL_QUORUM` voit
l'écriture.

### Elasticsearch : `create`, jamais `index`

Un *data stream* n'accepte **que** `create`. Il est append-only par conception,
ce qui est exactement juste pour des événements, et c'est la raison pour
laquelle le mapping est `dynamic: strict` : une faute de frappe dans un nom de
champ échoue bruyamment au lieu d'ajouter silencieusement un champ au mapping.

### Un échec d'un magasin n'empêche pas l'écriture dans l'autre

Pendant un scénario chaos, il importe énormément de savoir si Cassandra et
Elasticsearch ont échoué **ensemble** ou si un seul a échoué. Les coupler
masquerait cette information.

## 4. Métriques

Exposées sur `:8000/metrics`, découvertes par les labels Swarm
(`prometheus.job=demo-producer`, `prometheus.port=8000`).

| Métrique | Type | Usage |
|---|---|---|
| `demo_producer_events_total{target}` | compteur | débit réellement écrit, par magasin |
| `demo_producer_errors_total{target}` | compteur | **le critère du CDC §8.2 n°5** : doit rester à 0 |
| `demo_producer_write_duration_seconds{target}` | histogramme | latence d'un lot ; les *buckets* commencent à 5 ms parce qu'une écriture `LOCAL_QUORUM` nominale s'y trouve, et que la question pendant une perte de nœud est de savoir si elle passe à la centaine de millisecondes |
| `demo_producer_sensors` | jauge | nombre de capteurs simulés |

Toutes sont déjà consommées par le tableau de bord Grafana **« Datalake »**
(`dw-datalake`), écrit en phase 4.

## 5. Le healthcheck ne teste **pas** Cassandra

`curl -sf http://127.0.0.1:8000/metrics` — et rien de plus profond, exprès.

Un healthcheck qui sonderait Cassandra redémarrerait le producteur exactement
quand Cassandra est indisponible : le compteur d'erreurs — la seule chose que ce
service produit d'utile — serait remis à zéro au moment précis où on le mesure.
Un producteur qui ne joint pas Cassandra doit **continuer à tourner et à
compter**.

## 6. Arrêt propre

`SIGTERM` est traité : le lot en cours est terminé, puis le processus sort.
Mourir en plein lot laisserait des lignes dans Cassandra sans document
correspondant dans Elasticsearch — un écart qui, pendant un scénario chaos,
ressemblerait à une perte de données et coûterait un après-midi à expliquer.
`stop_grace_period: 20s` laisse la place pour cela.

## 7. Exploitation

```bash
# Déployer AVANT la campagne chaos
make deploy-demo

# Ce qu'il écrit, vu de Prometheus
curl -s 'http://prometheus:9090/api/v1/query?query=sum(rate(demo_producer_events_total[5m]))' | jq

# Le critère du CDC §8.2 n°5
curl -s 'http://prometheus:9090/api/v1/query?query=sum(demo_producer_errors_total)' | jq

# Augmenter la charge (DEMO_RATE / DEMO_SENSORS dans .env), puis :
make deploy-demo

# Arrêter la charge sans retirer la stack
docker service scale demo_demo-producer=0
```

## 8. Points de vigilance

- **Le client `elasticsearch` est tenu sur la ligne 8.x**, pas la 9.x : il refuse
  de dialoguer avec un cluster d'une autre version majeure. Monter cette
  dépendance suppose de monter le cluster d'abord.
- **Les capteurs écrivent avec un TTL de 90 jours** (défini sur la table, pas
  ici) : le datalake ne grossit pas indéfiniment, et `TimeWindowCompactionStrategy`
  supprime des SSTables entières à l'expiration.
- **`events_by_site` est une table à `counter`** : elle ne peut pas porter de
  TTL (restriction Cassandra) et un incrément ne doit jamais être rejoué. Elle
  est minuscule — 1440 lignes par site et par jour.
- **Ce service n'est pas de la production.** Il ne doit pas tourner sur une
  plateforme réelle : `make deploy-demo` est une action explicite, jamais
  incluse dans `make deploy`.

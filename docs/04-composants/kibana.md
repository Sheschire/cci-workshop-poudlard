# Kibana — exploration des logs

> Composant de la stack `data`. Couvre `config/kibana/kibana.yml` et le service `kibana`.
>
> Décision structurante : [ADR-0007](../adr/0007-elasticsearch-logs-sans-loki.md).

## 1. Rôle dans la plateforme

Kibana sert à **l'exploration** : recherche ad hoc dans les logs, Discover, analyse de champs sur
un corpus qu'on ne connaît pas encore.

Les dashboards **opérationnels** sont dans Grafana, qui lit les mêmes index par sa datasource
Elasticsearch. Garder les deux est délibéré et non redondant :

| Besoin | Outil | Pourquoi |
|---|---|---|
| « corréler ce pic de latence Traefik avec les erreurs GLPI et la charge CPU » | **Grafana** | il seul met métriques et logs sur le même axe de temps |
| « qu'y a-t-il dans ce flux de logs que je n'ai jamais regardé ? » | **Kibana** | Discover, répartition automatique des valeurs par champ, filtres cliquables |
| « quels sont les 20 messages les plus fréquents, et lesquels ont changé depuis hier ? » | **Kibana** | agrégations exploratoires sans écrire de requête |

## 2. Topologie

| Propriété | Valeur | Raison |
|---|---|---|
| Replicas | **1**, flottant | interface sans état : ses objets sauvegardés vivent dans Elasticsearch, Swarm peut la replanifier n'importe où |
| Réseaux | `data` + `edge` | `data` pour joindre les trois nœuds ES, `edge` pour que Traefik la route |
| Exposition | `kibana.dockerwarts.lan`, `admin-chain-noauth@file` | allowlist + rate-limit, **sans** basic-auth : Kibana authentifie ses propres utilisateurs contre Elasticsearch |
| Mémoire | 1 Go | Node.js, plus modeste qu'une JVM mais pas négligeable sur un nœud de 6 Go |

Perdre Kibana coûte une replanification de 30 à 60 s et une reconnexion. C'est accepté : c'est un
outil d'exploration, pas un service rendu aux utilisateurs, et son RTO est largement dans les
objectifs du CDC §9.4.

## 3. `config/kibana/kibana.yml` — section par section

### 3.1 Serveur

| Réglage | Valeur | Explication |
|---|---|---|
| `server.publicBaseUrl` | `https://kibana.${DOMAIN}` | Kibana construit des liens **absolus** (URL courtes, permaliens d'objets sauvegardés). Mal réglé, les liens fonctionnent pour celui qui les crée et donnent un 404 à tous les autres |
| `server.rewriteBasePath` | `false` | Traefik ne réécrit rien : Kibana est servie à la racine de son propre nom d'hôte |
| `server.securityResponseHeaders.strictTransportSecurity` | `max-age=31536000` | exigé par Kibana 8 derrière un proxy qui termine le TLS |

### 3.2 Connexion à Elasticsearch

```yaml
elasticsearch.hosts: [http://es-1:9200, http://es-2:9200, http://es-3:9200]
elasticsearch.username: "kibana_system"
```

Les **trois** nœuds : Kibana répartit et bascule toute seule, donc perdre un nœud ES est
invisible.

Le compte est le compte de service intégré `kibana_system`, **jamais** le superutilisateur
`elastic` : une compromission de Kibana ne doit pas être une compromission du cluster.

`requestTimeout: 90000` — le défaut de 30 s est trop agressif pour une requête Discover portant
sur 90 jours de logs, sur trois petites VM.

### 3.3 Les secrets ne sont pas dans ce fichier

Ni le mot de passe, ni les clés de chiffrement n'apparaissent dans `kibana.yml`. Kibana ne sait
pas lire un secret Docker (pas de convention `*_FILE`, pas d'intégration keystore dans l'image),
mais l'image officielle **mappe les variables d'environnement sur les réglages**.

C'est le rôle de `config/common/secrets-entrypoint.sh` (voir [fluent-bit.md](fluent-bit.md#4-le-pont-secret--variable-denvironnement)) :
il transforme `ELASTICSEARCH_PASSWORD_FILE=/run/secrets/…` en `ELASTICSEARCH_PASSWORD`.

Pourquoi cela compte : un objet `config` Swarm est lisible par `docker config inspect` **depuis
n'importe quel manager**. Un mot de passe qui y figurerait serait exposé à toute personne ayant
accès au plan de contrôle. Un `secret` est monté en fichier avec des permissions restreintes et ne
fait pas partie de la définition du service.

Le compromis est énoncé franchement : la valeur finit dans l'environnement du processus, ce qui
est strictement moins bon qu'un fichier. C'est nettement mieux qu'un objet `config`, et c'est la
seule option que l'image offre.

### 3.4 Clés de chiffrement — le piège de la reprise

```yaml
xpack.encryptedSavedObjects.encryptionKey
xpack.security.encryptionKey
xpack.reporting.encryptionKey
```

Ces trois clés chiffrent **au repos** les objets sauvegardés, les cookies de session et les
travaux de reporting, dans l'index `.kibana`.

**Si elles changent, tout objet sauvegardé chiffré devient illisible** — silencieusement. C'est
pourquoi elles sont générées une fois par `scripts/init-secrets.sh` et appartiennent au coffre au
même titre que `dw_restic_password` : restaurer un snapshot Elasticsearch sans elles restaure des
données que Kibana ne peut plus déchiffrer.

Les trois pointent sur **un seul** secret (`dw_kibana_encryption_key`) : elles protègent les mêmes
objets, et une seule valeur au coffre vaut mieux que trois.

### 3.5 Fonctions désactivées

`telemetry`, `reporting`, `fleet`, `apm`, `newsfeed` : inutilisées ici, et chacune coûte de la
mémoire dans un processus Node sur un nœud de 6 Go, plus des tâches de fond qui interrogent
Elasticsearch. `newsfeed` ferait en plus un appel sortant vers Internet.

**`alerting` reste activé** alors que l'alerting de Kibana n'est pas utilisé (Alertmanager est la
source unique d'alertes, ADR-0009) : le désactiver casse plusieurs fonctions de Discover qui
dépendent de son gestionnaire de tâches.

### 3.6 Journalisation et langue

Journalisation JSON sur stdout, collectée comme n'importe quel conteneur. Le niveau est `warn` et
non `info` : Kibana journalise **chaque** requête HTTP, y compris la sonde de santé toutes les
10 s — à `info`, le log est du bruit.

`i18n.locale: fr-FR` : interface en français, cohérent avec la documentation (CDC §N7). Les noms
de champs et d'index restent en anglais — ce sont des données, pas de l'interface.

## 4. Data views

Provisionnées par `scripts/es-init.sh` via l'API des objets sauvegardés :

| Data view | Motif | Champ temporel |
|---|---|---|
| `dw-logs` | `logs-*` | `@timestamp` |
| `dw-events` | `datalake-events*` | `@timestamp` |

Un opérateur qui ouvre Kibana trouve donc Discover directement utilisable, au lieu d'un écran
« créez une data view » qui suppose de connaître le nom des index.

## 5. Supervision

| Élément | Détail |
|---|---|
| Sonde | blackbox HTTP via la VIP sur `https://kibana.dockerwarts.lan/api/status` |
| Alerte | `KibanaDown` — sonde HTTP en échec 1 min, **warning** (et non critical : c'est un outil d'exploration, pas un service critique) |
| Healthcheck | `/api/status` doit contenir `"level":"available"` — Kibana répond 200 même en état dégradé, la vérification porte donc sur le contenu |
| Dashboard | « Disponibilité & certificats » |

Kibana n'a pas d'exporter Prometheus. C'est assumé : la seule question qui compte est
« répond-elle ? », et la sonde blackbox y répond mieux qu'une métrique interne.

## 6. Sauvegarde

**Aucune sauvegarde dédiée.** Les objets sauvegardés vivent dans l'index système `.kibana`, inclus
dans les snapshots Elasticsearch via `include_global_state: true`. Les data views sont de toute
façon reprovisionnées par `es-init.sh`.

La seule chose à ne pas perdre est `dw_kibana_encryption_key` (§3.4).

## 7. Points d'attention

| Point | Détail |
|---|---|
| Clé de chiffrement | la perdre rend les objets sauvegardés chiffrés illisibles, sans message d'erreur clair. Coffre obligatoire |
| Un seul replica | déconnexion à chaque replanification. Passer à 2 replicas exigerait des sessions partagées, que Kibana ne gère pas comme Grafana |
| `publicBaseUrl` | à mettre à jour si le domaine change, sinon les permaliens partagés donnent des 404 |
| Digest non épinglé | `docker.elastic.co` inaccessible depuis l'environnement de développement — voir `config/unpinned-images.txt` |
| Version | doit rester sur la **même mineure** qu'Elasticsearch (8.19). Kibana refuse de démarrer contre un cluster de mineure différente |

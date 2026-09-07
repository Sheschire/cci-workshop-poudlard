# Grafana — visualisation

> Composant de la stack `monitoring`. Couvre `config/grafana/grafana.ini`,
> `config/grafana/provisioning/**`, les 12 dashboards de `config/grafana/dashboards/`,
> `scripts/lib/gen-dashboards.py` et `scripts/lib/check-grafana.py`.

## 1. Rôle dans la plateforme

Grafana est l'interface de supervision (exigence F4 du CDC). Elle lit **trois** sources et les
met sur le même axe de temps :

| Source | Contenu |
|---|---|
| Prometheus | toutes les métriques |
| Elasticsearch (`logs-*`) | les journaux |
| Elasticsearch (`datalake-events`) | les données métier |

C'est cette corrélation qui distingue Grafana de Kibana : « ce pic de latence Traefik coïncide
avec ces erreurs GLPI et cette charge CPU » n'est visible que là.

## 2. Ce qui rend Grafana réellement HA

```ini
[database]
type = mysql
host = db-proxy:3306
name = grafana
[session]
provider = mysql
```

C'est **le** réglage qui justifie la base `grafana` sur Galera (ADR-0005).

Avec le SQLite par défaut, chacun des deux replicas aurait son propre état : l'utilisateur serait
déconnecté une requête sur deux, un dashboard sauvegardé sur l'un serait invisible sur l'autre.
Pointer les deux sur la base partagée les rend **interchangeables** — ce que « 2 replicas » est
censé signifier.

Deux corollaires :

- `GF_SECURITY_SECRET_KEY` **doit être identique sur les deux replicas** : elle signe les cookies
  et chiffre les mots de passe des datasources en base. D'où le secret Docker
  `dw_grafana_secret_key` plutôt qu'une valeur générée par instance.
- `conn_max_lifetime = 14400` (4 h) : plus court que tout timeout sur le chemin HAProxy, pour
  qu'une connexion soit recyclée avant de pouvoir être coupée sous une requête.

## 3. `grafana.ini` — les points qui comptent

| Section | Réglage | Raison |
|---|---|---|
| `[server]` | `root_url = https://grafana.${DOMAIN}` | Grafana construit des liens **absolus** (partage, notifications). Mal réglé : des liens qui marchent pour leur auteur et donnent 404 aux autres |
| `[security]` | `cookie_secure`, `samesite=lax`, HSTS, CSP | cohérent avec les en-têtes posés par Traefik |
| | `disable_gravatar = true` | pas d'appel sortant vers gravatar.com pour chaque avatar |
| `[users]` | `allow_sign_up = false` | pas d'auto-inscription |
| | `default_timezone = Europe/Paris` | un horodatage sur un dashboard doit correspondre à celui du ticket GLPI et de Kibana |
| `[auth.anonymous]` | `enabled = false` | Grafana expose la topologie de l'infrastructure et est joignable **sans** allowlist (c'est un service utilisateur, comme GLPI) |
| `[log]` | `level = warn`, format JSON | à `info`, Grafana journalise chaque requête HTTP, y compris la sonde toutes les 15 s |
| `[explore]` | `enabled = true` | c'est ainsi qu'un opérateur passe d'un panneau à ses logs bruts. La raison principale pour laquelle Grafana et Kibana coexistent utilement |

### L'alerting Grafana est délibérément désactivé

```ini
[unified_alerting]
enabled = false
```

Alertmanager est la source **unique** d'alertes (ADR-0009). L'alerting de Grafana créerait un
**second** moteur, avec ses propres règles, son propre état et ses propres notifications — et rien
ne garantirait que les deux soient d'accord. Un ticket ouvert par l'un et pas par l'autre est pire
qu'aucune alerte.

Grafana **affiche** toujours les alertes d'Alertmanager, via sa datasource.

## 4. Provisioning — les UID fixes

```yaml
- name: Prometheus
  uid: dw-prometheus
```

Chaque datasource a un **UID fixe et stable**, et chaque dashboard le référence. Laisser Grafana
les générer produirait des UID différents sur chaque replica et à chaque reconstruction, et
**chaque panneau afficherait « Datasource not found »**.

C'est exactement ce que `scripts/lib/check-grafana.py` vérifie en CI (§6).

| Datasource | UID | Usage |
|---|---|---|
| Prometheus | `dw-prometheus` | défaut, toutes les métriques |
| Elasticsearch-Logs | `dw-es-logs` | `logs-*`, avec `logMessageField` et `logLevelField` |
| Elasticsearch-Datalake | `dw-es-datalake` | `datalake-events` |
| Alertmanager | `dw-alertmanager` | alertes actives |

Deux datasources Elasticsearch **séparées** plutôt qu'une avec un index générique : les deux ont
des rétentions, des mappings et des sémantiques différentes, et une datasource unique forcerait
chaque panneau du datalake à exclure les logs à la main.

`logMessageField: message` et `logLevelField: log_level` sont ce qui transforme le panneau Logs
d'« un tableau de JSON » en une vue de logs lisible et colorée. C'est la raison pour laquelle le
filtre Lua de Fluent Bit normalise `log_level` en amont.

### Les dashboards sont en lecture seule dans l'interface

```yaml
disableDeletion: true
allowUiUpdates: false
```

`allowUiUpdates: true` laisserait un utilisateur enregistrer ses modifications **en base**, où
elles divergeraient silencieusement de git et seraient perdues à la reconstruction suivante. La
façon de modifier un dashboard est d'éditer le générateur et de redéployer.

## 5. Les 12 dashboards — générés, pas écrits à la main

Un dashboard Grafana fait ~500 lignes de JSON profondément imbriqué, dont peut-être 15 sont le
contenu réel : la requête, le titre, l'unité. Écrits à la main, douze dashboards divergent
immédiatement — UID différents, intervalles de rafraîchissement différents, panneaux qui se
chevauchent parce qu'un `gridPos` a été mal saisi, et un panneau « No data » que personne ne
remarque.

`scripts/lib/gen-dashboards.py` les génère depuis **une seule spécification** :

- chaque panneau référence forcément un UID que `datasources.yml` déclare ;
- la disposition est **calculée** : deux panneaux ne peuvent pas se chevaucher ;
- changer une convention (rafraîchissement, plage de temps, mode de tooltip) est **une** édition ;
- le diff d'un changement de dashboard est lisible.

Le JSON produit est **commité** (Grafana provisionne depuis des fichiers), et la CI vérifie avec
`--check` que le contenu commité correspond bien à la spécification.

### Les douze (155 panneaux, 51 sections)

| # | UID | Titre | Contenu principal | Base |
|---|---|---|---|---|
| 1 | `dw-overview` | Vue d'ensemble | VIP, nœuds, applications, clusters, alertes actives | maison |
| 2 | `dw-nodes` | Nœuds | CPU, mémoire, disque, réseau, load, par nœud | Node Exporter Full (1860) |
| 3 | `dw-containers` | Conteneurs | CPU/RAM/IO par service Swarm, redémarrages | cAdvisor (14282) |
| 4 | `dw-traefik` | Traefik | RPS, latences p50/p95/p99, codes HTTP, TLS | Traefik (17346) |
| 5 | `dw-security` | Sécurité | décisions CrowdSec, scénarios, 401/403/404/429, SSH | maison |
| 6 | `dw-elasticsearch` | Elasticsearch | santé, shards, heap, indexation, disque, SLM | ES exporter (14191) |
| 7 | `dw-cassandra` | Cassandra | nœuds, latences, compactions, hints, GC | JMX, maison |
| 8 | `dw-galera` | MariaDB Galera | `wsrep_cluster_size`, flow control, QPS, HAProxy | MySQL (13106) + Galera |
| 9 | `dw-availability` | Disponibilité & certificats | sondes blackbox, disponibilité mesurée, expiration TLS | Blackbox (7587) |
| 10 | `dw-backup` | Sauvegardes | âge, durée, taille, état par job, SLM, MinIO | maison |
| 11 | `dw-logs` | Logs | volume et erreurs par service, panneaux Logs | maison |
| 12 | `dw-datalake` | Datalake | événements/s, par site/capteur, températures, latences | maison |

### Trois choix de présentation qui reviennent partout

| Choix | Raison |
|---|---|
| `spanNulls: false` | un trou dans les données doit **ressembler** à un trou. Le combler masquerait exactement la panne qu'on cherche |
| `tooltip.mode: multi` + `sort: desc` | sur un graphique à 3 nœuds, c'est la différence entre lire et deviner |
| `clamp_min(dénominateur, 0.001)` | sans lui, un trafic nul produirait `NaN` et le panneau resterait vide — le même piège que dans la règle `TraefikHigh5xx` |
| `container_memory_working_set_bytes` | et non `usage` : `usage` inclut le cache récupérable et surestime largement la consommation réelle |

## 6. `scripts/lib/check-grafana.py` — la garantie du critère 4.2

Le critère 4.2 du CDC est « les douze dashboards se chargent sans panneau vide ». La cause de très
loin la plus fréquente d'un panneau vide est une référence à un UID de datasource que rien ne
provisionne : Grafana affiche le panneau, écrit « Datasource not found » en petit gris, et tout le
reste a l'air normal.

Cette panne est invisible pour yamllint, pour `docker stack config` et pour un coup d'œil rapide
à l'interface. Elle est donc vérifiée en CI, avant tout déploiement.

Ce qui est contrôlé :

1. tout UID référencé est déclaré dans `datasources.yml` ;
2. toute expression PromQL n'utilise que des préfixes de métriques que la plateforme expose
   réellement (une faute de frappe donne aussi un panneau vide) ;
3. toute cible Elasticsearch a un `timeField` et une `query` ;
4. aucun UID de dashboard n'est dupliqué (Grafana n'en garderait qu'un, silencieusement) ;
5. aucun panneau n'est sans cible ;
6. le JSON commité correspond au générateur.

**Tests négatifs effectués** : un UID de datasource erroné et une dérive par rapport au générateur
sont tous deux détectés, avec un message qui nomme le fichier fautif.

Le tokenizer PromQL retire d'abord les littéraux, les sélecteurs d'étiquettes **et les clauses
`by (...) / without (...)`** — sans quoi les noms d'**étiquettes** seraient signalés comme des
métriques inconnues et le contrôle croulerait sous les faux positifs jusqu'à ce que plus personne
ne le lise.

## 6 bis. Les fichiers de configuration, un par un

| Fichier | Rôle | Section |
|---|---|---|
| `config/grafana/grafana.ini` | configuration du serveur : base Galera, clé de signature, anonymisation | §3 |
| `config/grafana/provisioning/datasources/datasources.yml` | les 4 sources de données, à **UID fixes** | §4 |
| `config/grafana/provisioning/dashboards/dashboards.yml` | le *provider* qui charge le répertoire des dashboards, en lecture seule | §4 |

Les douze dashboards sont **générés** par `scripts/lib/gen-dashboards.py` (§5) et
ne sont pas écrits à la main ; les modifier dans l'interface ne les modifie pas
en git. Chacun porte un UID stable, cité par les annotations `dashboard:` des
règles d'alerte et donc par les tickets GLPI.

| Fichier | UID | Contenu |
|---|---|---|
| `config/grafana/dashboards/01-overview.json` | `dw-overview` | état global de la plateforme, une ligne par service |
| `config/grafana/dashboards/02-nodes.json` | `dw-nodes` | CPU, mémoire, disque, réseau des 3 nœuds |
| `config/grafana/dashboards/03-containers.json` | `dw-containers` | ressources par conteneur (cAdvisor) |
| `config/grafana/dashboards/04-traefik.json` | `dw-traefik` | requêtes, codes de retour, latences par routeur |
| `config/grafana/dashboards/05-security.json` | `dw-security` | décisions CrowdSec, bannissements, TLS |
| `config/grafana/dashboards/06-elasticsearch.json` | `dw-elasticsearch` | santé du cluster, shards, indexation, ILM |
| `config/grafana/dashboards/07-cassandra.json` | `dw-cassandra` | latences lecture/écriture, compaction, hints |
| `config/grafana/dashboards/08-galera.json` | `dw-galera` | taille du cluster, flow control, certification |
| `config/grafana/dashboards/09-availability.json` | `dw-availability` | sondes blackbox, disponibilité par URL |
| `config/grafana/dashboards/10-backup.json` | `dw-backup` | âge, durée, taille et état de chaque sauvegarde |
| `config/grafana/dashboards/11-logs.json` | `dw-logs` | volumétrie des logs, taux d'erreur, sources |
| `config/grafana/dashboards/12-datalake.json` | `dw-datalake` | débit du datalake, erreurs `demo-producer`, latences d'écriture |

## 7. Supervision

| Élément | Détail |
|---|---|
| Endpoint | `:3000/metrics`, labels `prometheus.job=grafana` |
| Sonde | blackbox HTTP sur `/api/health` via la VIP |
| Alerte | `GrafanaDown` (sonde en échec 1 min, critical) |
| Exposition | `grafana.dockerwarts.lan` + `app-chain@file` — **pas** d'allowlist : c'est un service utilisateur qui authentifie lui-même |

## 8. Sauvegarde

| Élément | Sauvegardé | Méthode |
|---|---|---|
| Dashboards, datasources | **oui**, en git | c'est la meilleure sauvegarde possible : versionnée et révisable |
| Utilisateurs, préférences, dashboards créés à la main | **oui** | ils sont dans la base `grafana`, couverte par `backup-galera` |
| `grafana_data` (plugins) | non | reconstructible |

Le secret `dw_grafana_secret_key` doit être au coffre : sans lui, les mots de passe des
datasources stockés en base sont indéchiffrables après une restauration.

## 9. Points d'attention

| Point | Détail |
|---|---|
| `GF_SECURITY_SECRET_KEY` | **identique sur les deux replicas**, sinon un utilisateur authentifié sur l'un est rejeté par l'autre |
| Base partagée | sans elle, « 2 replicas » ne veut rien dire. Ne jamais repasser en SQLite |
| Modifier un dashboard | éditer `scripts/lib/gen-dashboards.py`, régénérer, commiter. Une modification dans l'interface est perdue |
| `root_url` | à mettre à jour si le domaine change, sinon les liens partagés donnent 404 |
| Alerting Grafana | rester désactivé. L'activer créerait une seconde source d'alertes en désaccord avec la première |

# Alertmanager — routage, groupement et inhibition des alertes

> Composant de la stack `monitoring`. Couvre `config/alertmanager/alertmanager.yml`,
> `scripts/lib/render-alertmanager.py` et le service `alertmanager`.

## 1. Rôle dans la plateforme

Le rôle d'Alertmanager n'est **pas** « envoyer une notification ». C'est de transformer une rafale
d'alertes brutes en un petit nombre de tickets **actionnables** :

1. **dédupliquer** les deux instances Prometheus identiques ;
2. **grouper** les alertes liées pour qu'un incident = un ticket ;
3. **inhiber** les conséquences d'une cause racine, pour que la perte d'un nœud ouvre **un**
   ticket au lieu d'une douzaine.

Sans lui, la perte d'un nœud produirait : `NodeDown` ×2 (une par Prometheus), plus node-exporter,
cAdvisor, le membre Galera, le membre Cassandra, le membre Elasticsearch, l'instance Traefik,
l'agent CrowdSec… soit une vingtaine de tickets pour **un** incident et **une** action.

## 2. Topologie — trois replicas en cluster gossip

```
  Prometheus A ──┐                  ┌── alertmanager.1 ──┐
                 ├──► tasks.alertmanager ── alertmanager.2 ──┤ gossip
  Prometheus B ──┘                  └── alertmanager.3 ──┘
                                              │
                                              ▼
                                       alert2glpi → GLPI
```

Le cluster gossip est ce qui **rend la déduplication possible** : les trois membres partagent la
liste des notifications déjà envoyées. Une alerte reçue par les trois produit **un** ticket.

Perdre un membre laisse un quorum ; `AlertmanagerClusterDegraded` prévient qu'une perte
supplémentaire produirait des tickets en double.

`--cluster.peer=tasks.alertmanager:9094` : chaque replica découvre les deux autres par le DNS
Swarm, sans liste statique à maintenir quand ils sont replanifiés.

## 3. `alertmanager.yml` — section par section

### 3.1 `global.resolve_timeout`

```yaml
resolve_timeout: 5m
```

Combien de temps une alerte reste `firing` après que Prometheus a cessé de l'envoyer. Il doit
valoir **au moins 2 à 3 intervalles d'évaluation** (15 s ici) : sinon une seule évaluation
manquée marquerait l'alerte résolue, **fermerait le ticket GLPI**, et le rouvrirait quelques
secondes plus tard.

### 3.2 Groupement

```yaml
group_by: ["alertname", "node", "component"]
```

`node` dans la clé est ce qui fait que « disque plein sur node1 » et « disque plein sur node2 »
sont **deux tickets distincts** — ce sont deux problèmes nécessitant deux actions. Grouper sur le
seul `alertname` les fusionnerait en un ticket refermé dès que l'un des deux est corrigé.

| Réglage | Valeur | Raison |
|---|---|---|
| `group_wait` | 30 s | laisse arriver les alertes liées du même incident, sans retarder sensiblement une alerte critique |
| `group_interval` | 5 min | avant de notifier de **nouvelles** alertes ajoutées à un groupe existant |
| `repeat_interval` | 4 h | une répétition crée un suivi GLPI : trop court, le ticket se remplit de bruit ; trop long, un incident oublié reste silencieux |

Les alertes `critical` ont leur propre route, plus réactive (`group_wait: 10s`,
`repeat_interval: 1h`).

### 3.3 Inhibition — la fonctionnalité la plus utile du fichier

Le champ `equal:` est le point crucial : il liste les étiquettes qui doivent **correspondre**
entre la source et la cible. Mal réglé, soit rien n'est inhibé, soit une alerte sur un nœud sain
est masquée par un incident sur un autre — ce qui est **bien pire** que pas d'inhibition du tout.

| # | Source | Cible | `equal` | Raison |
|---|---|---|---|---|
| 1 | `NodeDown` | toute alerte critical/warning | **`["node"]`** | seules les alertes portant le **même** `node` sont inhibées. Une alerte sans étiquette `node` (une sonde blackbox via la VIP) n'est **pas** inhibée — et c'est correct : « GLPI est down » reste une information même pendant la perte d'un nœud, car elle dit que la bascule **n'a pas fonctionné** |
| 2 | `VipUnreachable` | GLPIDown, GrafanaDown, KibanaDown, MinIODown, GLPISlow | `[]` | ces alertes n'ont aucune étiquette commune avec la source (ce sont des sondes de cibles différentes), mais le lien causal est total : sans la VIP, **rien** n'est joignable |
| 3 | `severity=critical` | `severity=warning` | `["alertname","node","component"]` | `NodeDiskFull` (critical) tait `NodeDiskFillingUp` (warning) sur le même point de montage |
| 4 | `GaleraQuorumLost` / `CassandraQuorumAtRisk` | l'alerte de taille correspondante | `[]` | le quorum perdu est la vraie information |
| 5 | `ESClusterRed` | `ESClusterYellow`, `ESDiskWatermark` | `[]` | |
| 6 | `MariaDBDown` | `GaleraNotSynced`, `GaleraFlowControlPaused` | `["instance"]` | un membre mort ne peut pas être « désynchronisé » : c'est le même fait |
| 7 | `MinIODown` | `BackupFailed`, `BackupTooOld`, `ESSnapshotFailed` | `[]` | sans cela, **une** panne MinIO ouvrirait un ticket **par job** de sauvegarde |
| 8 | `TraefikDown` | `TraefikHigh5xx` | `["node"]` | |

La règle 1 est la plus subtile, et son commentaire dans le fichier explique précisément pourquoi
`equal: ["node"]` et pas `equal: []` : la différence entre « masquer les conséquences » et
« masquer un incident réel sur une autre machine ».

### 3.4 Récepteurs

| Récepteur | Usage |
|---|---|
| `glpi` | **le récepteur par défaut**. Webhook vers `http://alert2glpi:8080/alert`, `send_resolved: true` |
| `email` | optionnel, **retiré au rendu** si SMTP n'est pas configuré (§4) |
| `null` | pour `Watchdog` : une alerte volontairement permanente dont l'**absence** signale que la chaîne est cassée. Elle ne doit jamais créer de ticket |

**`send_resolved: true` est ce qui ferme la boucle** : alert2glpi transforme une notification
`resolved` en passage du ticket au statut Résolu. Sans lui, les tickets ne seraient que créés, et
quelqu'un devrait les fermer à la main — ce que personne ne fait.

`max_alerts: 0` : ne jamais tronquer un lot. Chaque alerte doit être vue.

## 4. `scripts/lib/render-alertmanager.py` — la condition que la substitution ne sait pas faire

La notification par courriel est **optionnelle** (CDC annexe D : `SMTP_HOST` et `ALERT_EMAIL_TO`
peuvent être vides). Mais Alertmanager **refuse de démarrer** sur une entrée `email_configs` dont
le champ `to` est vide :

```
FAILED: missing to address in email config
```

et un récepteur pointant sur `:25` échouerait chaque notification, ce qui déclencherait
`AlertmanagerNotificationsFailing` en permanence — la pile de supervision alertant sur sa propre
fonctionnalité optionnelle inutilisée.

Le fichier de base déclare donc la route et le récepteur **en entier**, et ce script les
**retire** quand SMTP n'est pas configuré. Retirer plutôt qu'ajouter garde
`config/alertmanager/alertmanager.yml` comme un document complet, valide et lisible seul.

Les deux cas ont été vérifiés avec `amtool check-config` :

| Cas | Résultat |
|---|---|
| SMTP absent (défaut) | `SUCCESS` — 2 récepteurs, route email retirée |
| SMTP configuré | `SUCCESS` — 3 récepteurs, route email conservée |

## 5. Supervision

| Élément | Détail |
|---|---|
| Endpoint | `:9093/metrics`, labels `prometheus.job=alertmanager` |
| Métriques clés | `alertmanager_cluster_members`, `alertmanager_notifications_failed_total`, `alertmanager_alerts`, `alertmanager_notification_latency_seconds` |
| Alertes | `AlertmanagerClusterDegraded` (< 3 membres, warning), `AlertmanagerNotificationsFailing` (**critical**) |
| Exposition | `alertmanager.dockerwarts.lan` + `admin-chain@file` (allowlist + basic-auth) |

## 6. Sauvegarde

| Élément | Sauvegardé | Raison |
|---|---|---|
| `alertmanager_data` (silences, état des notifications) | **non** | l'état est reconstruit en quelques minutes par les Prometheus qui ré-émettent leurs alertes. Les silences sont temporaires par nature |
| Configuration | **oui**, en git | c'est le seul élément qui compte |

## 7. Points d'attention

| Point | Détail |
|---|---|
| `resolve_timeout` | le baisser sous 3 intervalles d'évaluation ferait clignoter les tickets GLPI |
| `equal:` des inhibitions | une erreur ici masque de vraies alertes. Toute modification doit être raisonnée sur les étiquettes réellement portées |
| Trois replicas | descendre à 2 fonctionne, mais une perte supplémentaire produirait des tickets en double |
| Le récepteur `null` | ne pas le supprimer : `Watchdog` créerait alors un ticket permanent |
| SMTP | activer les DEUX variables (`SMTP_HOST` **et** `ALERT_EMAIL_TO`), sinon le récepteur reste retiré |

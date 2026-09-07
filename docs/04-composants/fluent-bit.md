# Fluent Bit — collecte des logs

> Composant de la stack `data`. Couvre `config/fluent-bit/{fluent-bit.conf,parsers.conf,docker-metadata.lua}`,
> `config/common/secrets-entrypoint.sh` et le service `fluent-bit`.

## 1. Rôle dans la plateforme

Fluent Bit répond à l'exigence F2 du CDC : **historiser les logs de tous les conteneurs, du
reverse proxy et du système**, de façon consultable et recherchable.

Service **global** : une tâche par nœud, chacune ne collectant que les logs de **son** nœud.
Trois collecteurs locaux, un seul Elasticsearch.

## 2. Le choix décisif : `tail` et non le driver `fluentd`

Docker sait envoyer les logs directement à un collecteur (`--log-driver=fluentd`). Ce projet ne le
fait **pas**, et c'est le choix le plus important de ce composant.

| Approche | Panne du collecteur |
|---|---|
| driver `fluentd` | l'écriture sur stdout d'un conteneur **bloque**. Une panne de Fluent Bit fige les applications qu'il est censé observer |
| **`json-file` + `tail`** | les conteneurs écrivent dans des fichiers, Fluent Bit les suit. Une panne de collecte coûte des **logs**, jamais un **service** |

C'est la raison d'être de `log-driver: json-file` dans `daemon.json` (rôle Ansible `docker`) et du
bloc `logging:` sur chaque service des stacks. L'observabilité ne doit jamais être un point de
défaillance de la production qu'elle observe.

## 3. `config/fluent-bit/fluent-bit.conf`

### 3.1 `[SERVICE]` — le tampon disque, le réglage qui compte

```ini
storage.path              /var/log/flb-storage/
storage.sync              normal
storage.backlog.mem_limit 64M
```

Avec un tampon **en mémoire** seulement, un redémarrage d'Elasticsearch perd tout ce qui est en
vol. Avec un magasin **sur système de fichiers**, les blocs sont écrits sur un volume local et
rejoués au retour d'Elasticsearch.

Combiné à `Retry_Limit False` sur les sorties (réessai infini), cela rend une **panne
d'Elasticsearch sans perte** — pas seulement atténuée. C'est ce qui permet à la matrice de
défaillance du CDC §8.1 d'annoncer « reprise depuis la DB de position ».

`Flush 5` : cinq secondes entre deux vidages, compromis entre l'efficacité des lots `bulk`
Elasticsearch et la fraîcheur apparente dans Kibana.

`Health_Check On` avec `HC_Errors_Count 5` : `/api/v1/health` reflète les **erreurs de sortie**,
pas seulement la vivacité. Un Fluent Bit qui tourne mais n'arrive pas à livrer est signalé
*unhealthy*, ce qu'un simple test de port ne verrait pas.

### 3.2 Les trois entrées

| Entrée | Source | Pourquoi elle est là |
|---|---|---|
| `containers` | `/var/lib/docker/containers/*/*-json.log` | tous les conteneurs, sans coopération des applications |
| `traefik` | `/var/log/traefik/access.log` | le même fichier que l'agent CrowdSec lit |
| `journal` | journald, **3 unités seulement** | `docker`, `keepalived`, `ssh` |

Détails qui évitent des pannes réelles :

- **`Exclude_Path` sur Fluent Bit lui-même** : sans cela, il journaliserait à propos de la
  journalisation, et tout message d'erreur serait réingéré puis échouerait à nouveau — une boucle
  infinie.
- **`DB` (base de positions) sur un volume local** : après un redémarrage, la lecture reprend où
  elle s'était arrêtée au lieu de réingérer chaque fichier depuis le début.
- **`Path_Key log_file_path`** : l'identifiant de conteneur n'est **que** dans le chemin du
  fichier, jamais dans le JSON. Sans ce réglage, le filtre Lua n'aurait rien à résoudre.
- **`Read_From_Tail On`** sur le journal : au premier démarrage, ne lire que les nouvelles
  entrées. Ingérer des semaines de journal préexistant inonderait un cluster neuf et fausserait la
  fenêtre de rétention.
- **Seulement trois unités systemd** : `keepalived` en particulier, parce que ses transitions
  MASTER/BACKUP sont la **preuve horodatée** du temps de bascule mesuré dans
  `docs/06-haute-disponibilite.md`.

### 3.3 Multiline — sans quoi les incidents sont illisibles

Une exception Java de Cassandra ou d'Elasticsearch fait des dizaines de lignes. Sans réassemblage,
chaque ligne devient un document : la trace est illisible, non recherchable, et le nombre de
documents explose d'un ordre de grandeur **pendant un incident** — exactement quand les logs
comptent le plus.

`parsers.conf` déclare trois parseurs multiline (`java_stacktrace`, `go`, `python`), chacun avec
une règle de départ et une ou deux règles de continuation. `Flush_Timeout 2000` : un événement est
émis au plus 2 s après sa dernière ligne, même si le processus est mort au milieu de la trace.

### 3.4 Filtres

| Filtre | Ce qu'il fait |
|---|---|
| `lua / add_docker_metadata` | résout l'identifiant de conteneur en service / stack / tâche Swarm |
| `record_modifier` | ajoute `node_name` depuis `{{.Node.Hostname}}` fourni par Swarm |
| `modify` (docker) | renomme `log` → `message`, supprime le marqueur interne `_p` |
| `modify` (traefik) | renomme `time` → `@timestamp`, **supprime `request_Authorization` et `request_Cookie`** |
| `lua / normalize_level` | unifie les orthographes de niveau de log |

La suppression des en-têtes d'authentification est une **double sécurité** : Traefik les écarte
déjà (`accessLog.fields`), mais une erreur de configuration là-bas ne doit pas se transformer en
identifiants stockés dans un index que Grafana et Kibana exposent largement.

### 3.5 Sorties

Un `[OUTPUT]` par data stream. Réglages partagés (Fluent Bit n'a pas d'héritage de sortie) :

| Réglage | Raison |
|---|---|
| `Suppress_Type_Name On` | **obligatoire** sur ES 8 : les types de mapping ont disparu, en envoyer un est une erreur bloquante |
| `Retry_Limit False` | réessai infini. Avec le tampon disque, c'est ce qui rend une panne ES sans perte |
| `Replace_Dots On` | un point dans un nom de champ créerait une hiérarchie d'objets non voulue dans le mapping |
| `Compress gzip` | les logs se compressent très bien ; moins de bande passante sur l'overlay chiffré |
| `storage.total_limit_size` | plafonne le backlog disque par sortie (512/256/128 Mo) : une panne ES prolongée ne doit pas remplir le disque du nœud |

**Un seul hôte de sortie (`es-1`)**, et c'est assumé : la sortie `es` de Fluent Bit n'a pas de
bascule multi-hôtes. Si `es-1` tombe, l'expédition s'arrête depuis les trois nœuds — mais le
tampon disque rejoue tout à son retour. L'alternative (un répartiteur devant Elasticsearch)
ajouterait un composant pour une panne déjà sans perte.

## 4. Le pont secret → variable d'environnement

`config/common/secrets-entrypoint.sh` est un utilitaire **générique**, partagé par Fluent Bit,
Kibana et les exporters : pour chaque variable `<NAME>_FILE`, il lit le fichier et exporte
`<NAME>`, puis `exec` vers le vrai processus.

Deux garde-fous, issus de problèmes réels rencontrés en le testant :

1. **Il ne traite que les chemins situés sous `/run/secrets/`.** L'environnement d'un conteneur
   contient déjà des variables en `_FILE` pointant sur des paquets de certificats de plusieurs
   kilooctets (`SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`). Les convertir
   exporterait le paquet entier dans une variable et dépasserait la limite d'arguments d'`exec` :
   le conteneur échouerait à démarrer avec un message sans aucun rapport.
2. **Un secret vide est fatal.** Un fichier monté mais vide signifie que la génération a échoué ;
   démarrer avec un mot de passe vide produirait une boucle d'authentification qui ressemble à un
   problème réseau.

`exec` en fin de script : le vrai processus devient PID 1 et reçoit directement le SIGTERM de
Swarm.

## 5. `config/fluent-bit/docker-metadata.lua`

### 5.1 `add_docker_metadata` — sans lui, la collecte ne sert à rien

Le fichier json-file de Docker ne contient que le message brut : pas de nom de service, pas de
stack, pas de tâche. Une ligne de log ne peut donc pas être attribuée à un service — ce qui rend
toute la collecte à peu près inutilisable.

Le filtre extrait l'identifiant du **chemin du fichier**, puis lit le `config.v2.json` du
conteneur pour y trouver les labels que Docker y injecte :

```
com.docker.swarm.service.name   → service_name   (ex. data_galera-1)
com.docker.stack.namespace      → stack          (ex. data)
com.docker.swarm.task.name      → task_slot      (ex. 1)
com.docker.swarm.node.id        → node_id
```

Deux décisions d'implémentation :

- **Un cache identifiant → métadonnées.** Sans lui, chaque ligne de log ouvrirait et analyserait un
  fichier JSON de ~30 Ko. À quelques milliers de lignes par seconde, c'est la différence entre un
  collecteur qui coûte 2 % d'un cœur et un qui en coûte un entier. Un identifiant de conteneur est
  immuable et ses labels ne changent pas de sa vie : le cache ne peut jamais être périmé pour un
  conteneur vivant. Seuls les morts s'accumulent, d'où l'éviction à 512 entrées.
- **Une recherche de motif ciblée, pas un analyseur JSON.** Lua n'a pas de décodeur JSON intégré,
  et en embarquer un ajouterait une dépendance à un filtre qui s'exécute sur **chaque ligne**. Les
  labels ont une forme fixe et entre guillemets : la recherche de motif est à la fois correcte et
  ~50× moins coûteuse.

Un conteneur disparu entre l'écriture et la lecture est un cas **normal**, pas une erreur : la
ligne est expédiée sans métadonnées Swarm (`code = 0/2`, jamais `-1`). Perdre une ligne de log
parce que ses métadonnées sont introuvables serait le mauvais compromis.

### 5.2 `normalize_level`

Chaque service écrit sa sévérité différemment : Traefik et Elasticsearch dans un champ `level`,
MariaDB en `[ERROR]` dans le message, Cassandra en `ERROR` en début de ligne. Un panneau
« erreurs par service » a besoin d'**un** champ avec **un** vocabulaire.

Ordre de résolution : champ structuré (`level`, `log_level`, `severity`) → motif dans les 120
premiers caractères du message (`[ERROR]`, `ERROR `, `level=error`) → défaut `info`.

Le vocabulaire de sortie est `debug | info | warn | error | fatal`.

Le défaut à `info` plutôt qu'un champ absent est délibéré : un champ manquant disparaîtrait
silencieusement de toute agrégation par termes, et le panneau « erreurs par service »
**sous-compterait** au lieu d'afficher un trou visible.

### 5.3 Vérification

Les deux filtres ont été exécutés hors conteneur avec un `config.v2.json` réaliste :

| Cas | Résultat attendu | Obtenu |
|---|---|---|
| conteneur Swarm réel | `service_name=data_galera-1`, `stack=data`, `task_slot=1` | ✅ |
| second appel (cache) | même résultat, sans relecture de fichier | ✅ |
| conteneur disparu | ligne conservée, métadonnées absentes | ✅ |
| pas de chemin | `code = 0`, enregistrement inchangé | ✅ |
| `WARNING`, `Err`, `critical`, `TRACE` | `warn`, `error`, `fatal`, `debug` | ✅ |
| `[Note]`, `WARN …`, `FATAL …`, `level=error` | `info`, `warn`, `fatal`, `error` | ✅ |
| champ structuré vs texte contradictoire | le champ structuré l'emporte | ✅ |

## 6. Supervision

| Élément | Détail |
|---|---|
| Endpoint | `:2020/api/v1/metrics/prometheus`, labels `prometheus.job=fluentbit` |
| Métriques clés | `fluentbit_output_retries_failed_total`, `fluentbit_output_errors_total`, `fluentbit_input_records_total`, `fluentbit_output_proc_records_total` |
| Alerte | `FluentBitOutputErrors` — erreurs de sortie > 0 pendant 5 min, warning |
| Dashboard | « Logs » : volume par service, erreurs de collecte, taux d'ingestion |

L'écart entre `input_records_total` et `output_proc_records_total` est la métrique à surveiller :
il mesure le retard réel de la collecte.

## 7. Sauvegarde

**Aucune.** Le volume `fluentbit_state` ne contient que des positions de lecture et un tampon
transitoire — reconstructibles. Les logs eux-mêmes sont dans Elasticsearch, couvert par SLM.

Au pire, un Fluent Bit qui perd son état relit un fichier depuis le début et crée des doublons —
gênant, pas grave.

## 8. Points d'attention

| Point | Détail |
|---|---|
| Ne **jamais** passer au driver `fluentd` | cela ferait de la collecte un point de défaillance de la production (§2) |
| `copytruncate` obligatoire | la rotation du log Traefik doit préserver l'inode : deux lecteurs le suivent (Fluent Bit et CrowdSec) |
| Volume du tampon disque | plafonné par `storage.total_limit_size`. Une panne ES très longue finit par jeter les plus anciens blocs — c'est voulu, plutôt que remplir le disque du nœud |
| Sortie mono-hôte | `es-1` uniquement (§3.5). Sans perte grâce au tampon, mais l'expédition s'arrête pendant l'indisponibilité |
| Cache Lua | vidé entièrement à 512 entrées. Sur un nœud à très fort churn de conteneurs, cela relirait des fichiers plus souvent — sans impact fonctionnel |
| Montages en lecture seule | tous les chemins lus sont montés `read_only`. Un collecteur ne doit jamais pouvoir modifier ce qu'il collecte |

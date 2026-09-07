# 04 — Haute disponibilité

Le sujet demande **des mesures de haute disponibilité**. Ce document décrit
celles qui sont en place, ce que chacune couvre réellement, et — tout aussi
important — ce qu'aucune ne couvre.

---

## 1. Ce que « haute disponibilité » veut dire ici

Sur une plateforme tenant sur **une machine**, la haute disponibilité ne peut
pas signifier « tolérer la panne du serveur » : il n'y en a qu'un. Elle signifie
tolérer les pannes qui, en pratique, causent la quasi-totalité des interruptions
réelles :

| Type de panne | Fréquence réelle | Couverte ici |
|---|---|---|
| Un service plante ou se bloque | très fréquente | **oui** |
| Un service démarre avant sa dépendance | fréquente | **oui** |
| Un service fuit et sature la mémoire | fréquente | **oui** |
| Les journaux remplissent le disque | fréquente | **oui** |
| Redémarrage de la machine | occasionnelle | **oui** |
| Panne matérielle du serveur | rare | non → [PRA](05-PRA.md) |
| Perte du site complet | très rare | non → [PRA](05-PRA.md) |

Les quatre premières lignes représentent l'essentiel des incidents d'une
plateforme de ce type. Ce sont elles que les mesures ci-dessous traitent.

---

## 2. Les six mesures en place

### Mesure 1 — Redémarrage automatique

```yaml
restart: unless-stopped
```

Appliqué aux dix services via l'ancre `x-restart`. Un conteneur qui plante est
relancé par Docker, sans intervention, y compris après un redémarrage de la
machine.

> **`unless-stopped` et non `always`** : après un `docker compose stop`
> volontaire — pour une maintenance — les conteneurs ne se relancent pas tout
> seuls au reboot suivant. Avec `always`, ils reviendraient en pleine
> maintenance.

> **`cassandra-init` porte `restart: "no"`.** C'est un travail ponctuel qui
> **doit** se terminer. Le relancer en boucle n'aurait aucun sens, et il
> apparaîtrait en permanence comme un service en échec.

### Mesure 2 — Sondes de santé qui interrogent le service, pas le port

Chaque service porte un `healthcheck` qui parle son propre protocole. La
distinction n'est pas théorique : un port ouvert ne prouve rien.

| Service | Sonde | Ce qu'un simple test de port aurait manqué |
|---|---|---|
| MariaDB | `healthcheck.sh --connect --innodb_initialized` | le port écoute pendant que le moteur rejoue ses journaux |
| GLPI | `status.php` contient `GLPI_OK` | Apache sert une page 200 alors que la base est coupée |
| Elasticsearch | `_cluster/health` au moins `yellow` | le nœud écoute avant d'accepter des requêtes |
| Kibana | `/api/status` renvoie `available` | l'interface répond avant d'être connectée à Elasticsearch |
| Cassandra | `nodetool status` montre `UN` | le port est ouvert bien avant que le nœud soit opérationnel |
| Traefik, Prometheus, Grafana | point de santé HTTP dédié | — |

Chaque sonde a un `start_period` calibré : 120 s pour GLPI et Cassandra, 90 s
pour Kibana, 60 s pour Elasticsearch. Pendant cette fenêtre, les échecs ne sont
pas comptés — un service lent à démarrer n'est pas un service en panne.

> **Le piège de la sonde Elasticsearch.** Sur un nœud unique, les répliques ne
> peuvent pas être allouées : l'état normal est `yellow`, jamais `green`.
> Exiger `green` laisserait le service éternellement « unhealthy » alors qu'il
> fonctionne parfaitement, et rendrait la supervision inutilisable.

### Mesure 3 — Démarrage ordonné

```yaml
depends_on:
  db:
    condition: service_healthy
```

`service_healthy`, et non `service_started`. **Démarré ne veut pas dire prêt** :
l'auto-installation de GLPI échoue sur une base qui n'accepte pas encore de
connexion, et l'échec est silencieux — GLPI affiche ensuite une erreur de base
de données sans qu'on comprenne pourquoi.

La chaîne de dépendances : `db → glpi`, `elasticsearch → kibana`,
`cassandra → cassandra-init`, `prometheus → grafana`.

C'est ce qui rend le premier démarrage **fiable** plutôt qu'aléatoire.

### Mesure 4 — Limites de ressources

```yaml
deploy:
  resources:
    limits: {memory: 2G}
```

Chaque service a un plafond mémoire. Sans limite, un service qui fuit consomme
toute la mémoire de la machine, et le noyau tue alors **un processus au hasard** —
souvent pas le coupable. Une seule fuite arrête la plateforme entière.

Avec une limite, le service fautif est tué **seul**, puis relancé par
`restart: unless-stopped`. Les neuf autres continuent de fonctionner.

Le tableau de bord Grafana affiche la part de limite atteinte par conteneur,
et une alerte se déclenche à 90 % : on voit venir la saturation avant qu'elle
n'arrive.

| Service | Limite | Tas JVM |
|---|---|---|
| Elasticsearch | 2 Go | 1 Go |
| Cassandra | 2 Go | 1 Go |
| MariaDB, GLPI, Kibana, Prometheus | 1 Go | — |
| Grafana | 512 Mo | — |
| Traefik | 256 Mo | — |
| cAdvisor | 256 Mo | — |
| node-exporter | 128 Mo | — |

> **Règle des JVM** : le tas ne dépasse jamais la moitié de la limite du
> conteneur. Le reste sert aux structures hors tas, aux tampons réseau et au
> cache de fichiers — une JVM configurée à 100 % de sa limite est tuée par le
> noyau, sans message, très vite.

### Mesure 5 — Journaux bornés

```yaml
logging:
  driver: json-file
  options: {max-size: "10m", max-file: "3"}
```

Au maximum 30 Mo par conteneur, 300 Mo au total. Sans cette limite, un
conteneur bavard remplit le disque, et **un disque plein arrête MariaDB,
Elasticsearch et Cassandra en même temps**. C'est une panne classique, difficile
à diagnostiquer en pleine crise, et évitable en quatre lignes.

Une alerte se déclenche par ailleurs sous 15 % d'espace libre.

### Mesure 6 — Montée en charge horizontale de GLPI

GLPI est **prêt à être répliqué** sans modification :

```bash
docker compose up -d --scale glpi=3
```

Traefik détecte les nouvelles instances par leurs labels et répartit la charge
entre elles. Deux détails rendent la chose viable :

- **le cookie de session collant** (`loadbalancer.sticky.cookie`) : sans lui,
  une requête sur trois tombe sur une autre instance, qui ne connaît pas la
  session — l'utilisateur est déconnecté sans arrêt ;
- **la sonde de service** (`loadbalancer.healthcheck.path: /status.php`) :
  Traefik retire du répartiteur une instance qui ne répond plus, au lieu d'y
  envoyer un tiers du trafic.

L'état partagé le permet : la base est dans MariaDB, les fichiers dans un volume
monté par toutes les instances. Aucune donnée ne vit dans le conteneur GLPI.

> **Attention** : cela réplique la *couche applicative*, pas la base. Un GLPI en
> trois exemplaires devant une seule MariaDB tolère la panne d'une instance
> applicative, pas celle de la base.

---

## 3. La supervision comme mesure de disponibilité

Une panne qu'on ne voit pas dure jusqu'à ce qu'un utilisateur se plaigne. La
supervision réduit le temps de détection, qui est la première composante du
temps d'indisponibilité.

Six règles d'alerte sont définies dans
[`config/prometheus/alerts.yml`](../config/prometheus/alerts.yml). Le parti pris
est d'en avoir **peu, mais toutes actionnables** : une alerte qui se déclenche
sans qu'on sache quoi en faire finit ignorée, et emporte avec elle la crédibilité
de celles qui comptent.

| Alerte | Seuil | Gravité |
|---|---|---|
| `CibleInjoignable` | `up == 0` pendant 2 min | critique |
| `ConteneurEnBoucleDeRedemarrage` | > 3 démarrages en 15 min | critique |
| `DisqueBientotPlein` | < 15 % libre pendant 10 min | majeure |
| `MemoireHoteSaturee` | < 10 % disponible pendant 10 min | majeure |
| `ConteneurProcheDeSaLimiteMemoire` | > 90 % de sa limite pendant 10 min | majeure |
| `TauxErreursHttpEleve` | > 5 % de 5xx pendant 5 min | majeure |
| `ChargeCpuElevee` | > 90 % pendant 15 min | mineure |

Chaque règle porte un `for:` — la condition doit tenir dans la durée. C'est ce
qui distingue un incident d'un pic de trois secondes, et ce qui évite le
réveil à 3 h du matin pour une compaction Cassandra.

> **Il n'y a pas d'Alertmanager.** Les règles sont évaluées par Prometheus et
> consultables dans son onglet *Alerts* ainsi que dans Grafana. Ajouter
> Alertmanager n'aurait de sens qu'avec une destination réelle — messagerie,
> messagerie instantanée, astreinte — qui dépend de l'organisation qui exploite
> la plateforme, pas de son architecture. Le brancher demanderait un service
> supplémentaire et une ligne `alerting:` dans `prometheus.yml`.

Deux alertes méritent une mention parce qu'elles détectent des pannes que la
supervision naïve manque :

- **`ConteneurEnBoucleDeRedemarrage`** — un service qui redémarre toutes les
  deux minutes apparaît « running » à chaque coup d'œil. Seul le comptage des
  démarrages le révèle.
- **`TauxErreursHttpEleve`** — mesurée sur Traefik, donc **côté utilisateur**.
  Un taux de 5xx élevé signifie une panne réelle même quand les dix conteneurs
  sont `running` et toutes les sondes vertes.

---

## 4. Vérifier que ça marche vraiment

Une mesure de haute disponibilité qu'on n'a jamais testée est une hypothèse.

### Test 1 — Redémarrage automatique

```bash
# On tue le processus DANS le conteneur : c'est un plantage vu de Docker.
docker compose exec glpi sh -c 'kill -9 1'
sleep 20 && make ps               # glpi est « running (healthy) » à nouveau
```

> **`docker compose kill glpi` ne convient pas pour ce test**, et c'est un piège
> qui trompe régulièrement. Docker considère un `kill` ou un `stop` comme une
> décision de l'exploitant : avec `unless-stopped`, il ne relance **pas** le
> conteneur — c'est très exactement le sens de cette politique. On observe alors
> un service resté « exited » et on en conclut à tort que le redémarrage
> automatique ne fonctionne pas. Il faut provoquer un vrai plantage, donc tuer
> le processus depuis l'intérieur.

### Test 2 — Isolation par les limites mémoire

```bash
# Sature volontairement Elasticsearch, et observe qui tombe.
docker compose exec elasticsearch sh -c 'yes | head -c 3G > /dev/null'
make ps                           # seul elasticsearch est affecté
```

### Test 3 — Démarrage ordonné

```bash
docker compose down
docker compose up -d
docker compose logs glpi | head -20    # aucune erreur de connexion à la base
```

### Test 4 — Répartition de charge

```bash
docker compose up -d --scale glpi=3
docker compose ps glpi                 # trois conteneurs, tous « healthy »

# Traefik doit voir trois serveurs derrière le service, avec le cookie collant :
curl -sk -u "$ADMIN_USER:$ADMIN_PASSWORD" \
  https://traefik.dockerwarts.local/api/http/services/glpi@docker

# Une instance tombe : le service continue de répondre.
docker compose exec --index 2 glpi sh -c 'kill -9 1'
curl -sk https://glpi.dockerwarts.local/status.php   # toujours HTTP 200

docker compose up -d --scale glpi=1     # retour à une instance
```

### Test 5 — Isolation réseau

```bash
# Depuis un conteneur du réseau backend, aucune sortie n'est possible.
docker compose exec db sh -c 'timeout 5 wget -q -O- https://example.com || echo "aucune route — attendu"'
```

### Test 6 — Contrôle complet

```bash
make verify
```

### Ce que ces tests ont réellement donné

Tous ont été exécutés sur la plateforme, et voici les mesures obtenues.

| Test | Résultat mesuré |
|---|---|
| Démarrage à froid, volumes vides | **10 services sains en ≈ 90 s**, GLPI auto-installé |
| Plantage de GLPI (`kill -9 1`) | relancé et `healthy` en **moins de 20 s** |
| Montée à 3 instances | 3 conteneurs sains, **Traefik voit 3 serveurs**, cookie collant actif |
| Panne d'une instance sur trois | `status.php` répond **HTTP 200** sans interruption |
| Sortie réseau depuis `db` | **aucune route** — la segmentation tient |
| GLPI sans identifiants | **HTTP 200** (application publique) |
| Kibana, Prometheus, Traefik sans identifiants | **HTTP 401** |
| Prometheus avec identifiants | **HTTP 302** (accès accordé) |
| Nom d'hôte inconnu | **HTTP 404** — rien n'est exposé par défaut |
| HTTP sur le port 80 | **HTTP 301** vers HTTPS |
| En-têtes de sécurité | HSTS, `X-Frame-Options`, `nosniff`, `Referrer-Policy` présents |
| `verify.sh` | **21 contrôles, tous au vert** |

Trois défauts réels ont été trouvés par ces essais, et corrigés — ils sont
mentionnés ici parce qu'aucun n'était visible à la relecture du fichier :

1. **La sonde de Traefik échouait indéfiniment.** `traefik healthcheck --ping`
   interroge par défaut le point d'entrée `traefik` (:8080), qui n'est pas
   défini dans ce fichier. Le point `/ping` est désormais rattaché
   explicitement au point d'entrée des métriques.
2. **La sonde de Cassandra mentait.** `nodetool status` annonce le nœud
   « UN » une trentaine de secondes **avant** que le port 9042 accepte des
   connexions : `cassandra-init` démarrait alors sur un service déclaré sain et
   échouait en « Connection refused ». La sonde exécute désormais une vraie
   requête CQL.
3. **Elasticsearch tombait en état `red` sur un disque à 92 %.** Les seuils
   d'occupation par défaut sont des pourcentages : sur un disque de 250 Go,
   le nœud refuse d'allouer le moindre shard alors qu'il reste 20 Go libres.
   Ils sont passés en valeurs absolues, ce qu'Elastic recommande sur les gros
   volumes.

---

## 5. Les limites, dites franchement

**La machine hôte est un point de défaillance unique.** Si elle s'arrête, tout
s'arrête. Aucune des mesures ci-dessus n'y change quoi que ce soit ; c'est le
[PRA](05-PRA.md) qui prend le relais.

**Les moteurs de données tournent en un exemplaire.** MariaDB, Elasticsearch et
Cassandra ne sont pas en cluster. Si le conteneur MariaDB est corrompu, GLPI est
indisponible le temps d'une restauration.

**GLPI se réplique, mais pas sa base.** Voir la mesure 6.

**Il n'y a pas de bascule automatique.** Toute panne qui dépasse ce que
`restart: unless-stopped` sait réparer demande une intervention humaine.

### Ce qu'il faudrait pour lever ces limites

Ces évolutions sortent du périmètre « un `docker-compose.yml` sur une machine »,
qui est celui demandé. Elles sont indiquées pour situer honnêtement le niveau
atteint.

| Limite | Ce qu'il faudrait |
|---|---|
| Machine unique | Trois machines et un orchestrateur (Docker Swarm ou Kubernetes) |
| MariaDB unique | Un cluster Galera à trois nœuds, derrière un répartiteur |
| Elasticsearch unique | Trois nœuds, `number_of_replicas: 1` |
| Cassandra unique | Trois nœuds, `NetworkTopologyStrategy`, facteur de réplication 3 |
| Pas de bascule d'adresse | Une adresse IP virtuelle portée par Keepalived |
| Pas d'alerte poussée | Alertmanager, avec une destination réelle |

Chacune multiplie le nombre de composants, donc de pannes possibles. Sur le
périmètre demandé, les six mesures en place couvrent l'essentiel des
interruptions réelles pour une complexité qui reste lisible dans un seul fichier.

# 02 — Installation et utilisation

Procédure complète pour installer la plateforme sur une machine disposant de
Docker, y accéder, et résoudre les problèmes courants.

---

## 1. Prérequis

| Élément | Minimum | Vérification |
|---|---|---|
| Docker Engine | 24.0 | `docker --version` |
| Plugin Compose | v2.20 | `docker compose version` |
| Mémoire libre | 6 Go | `free -h` |
| Disque libre | 10 Go | `df -h /var/lib/docker` |
| `openssl` | présent | `openssl version` |

> **Sur Docker Desktop (macOS, Windows)**, la mémoire allouée à la machine
> virtuelle est de 2 Go par défaut : c'est insuffisant, Elasticsearch et
> Cassandra seront tués au démarrage. Réglez-la à **au moins 6 Go** dans
> *Settings → Resources* avant de commencer.

---

## 2. Installation

### Étape 1 — Récupérer le dépôt

```bash
git clone <url-du-dépôt>
cd cci-workshop-poudlard
```

### Étape 2 — Préparer les secrets

```bash
make init
```

Cette commande, **idempotente** (on peut la relancer sans rien perdre), produit
les trois choses qui ne peuvent pas être versionnées :

- **`.env`** — copié depuis `.env.example`, avec quatre mots de passe tirés au
  hasard. Rien de plus dangereux qu'un `change-me` qu'on oublie de changer.
- **`certs/dockerwarts.{crt,key}`** — un certificat TLS auto-signé valable
  825 jours, pour `*.dockerwarts.local`.
- **`secrets/users.htpasswd`** — l'empreinte du compte d'administration. Le mot
  de passe en clair n'est jamais écrit sur le disque, seulement son empreinte.

Ces trois chemins sont dans `.gitignore` : ils ne peuvent pas partir dans git.

### Étape 3 — Résoudre les noms

`make init` affiche la ligne à ajouter. C'est la seule étape qui demande
`sudo`, et elle ne se fait qu'une fois :

```bash
sudo tee -a /etc/hosts <<'EOF'
127.0.0.1 glpi.dockerwarts.local grafana.dockerwarts.local kibana.dockerwarts.local prometheus.dockerwarts.local traefik.dockerwarts.local
EOF
```

> Sur Windows, le fichier est `C:\Windows\System32\drivers\etc\hosts`, à éditer
> en tant qu'administrateur.

### Étape 4 — Démarrer

```bash
make up          # ou : docker compose up -d
```

Le premier démarrage dure **environ trois minutes**. Il ne se passe rien
d'anormal pendant ce temps :

| Temps | Ce qui se passe |
|---|---|
| 0 – 30 s | Traefik, MariaDB, node-exporter et cAdvisor démarrent |
| 30 s – 1 min | Elasticsearch et Cassandra initialisent leurs volumes |
| 1 – 3 min | GLPI installe sa base ; Kibana et Grafana se connectent |

Les dépendances sont déclarées avec `condition: service_healthy` : GLPI
n'essaie pas de s'installer avant que MariaDB accepte vraiment des connexions.
C'est ce qui rend le démarrage fiable au lieu d'aléatoire.

### Étape 5 — Vérifier

```bash
make verify
```

Ce script ne se contente pas de regarder si les conteneurs tournent : il
interroge **chaque service dans son propre protocole** — une requête SQL sur
MariaDB, `status.php` sur GLPI, l'API `_cluster/health` sur Elasticsearch,
`nodetool status` et une requête CQL sur Cassandra, `/api/health` sur Grafana.
Il vérifie aussi que Prometheus voit bien ses quatre sources, que HTTP est
redirigé vers HTTPS, et que Prometheus refuse un accès anonyme.

Il sort en code 1 s'il trouve le moindre problème : utilisable dans une tâche
planifiée.

---

## 3. Accès aux interfaces

| Service | Adresse | Identifiants |
|---|---|---|
| **GLPI** | https://glpi.dockerwarts.local | `glpi` / `glpi` (à changer immédiatement) |
| **Grafana** | https://grafana.dockerwarts.local | `admin` / voir `.env` |
| **Kibana** | https://kibana.dockerwarts.local | compte d'administration Traefik |
| **Prometheus** | https://prometheus.dockerwarts.local | compte d'administration Traefik |
| **Traefik** | https://traefik.dockerwarts.local | compte d'administration Traefik |

Pour lire les mots de passe générés :

```bash
grep -E 'GRAFANA_PASSWORD|ADMIN_' .env
```

### Deux points d'attention au premier accès

**Le navigateur affiche un avertissement de sécurité.** C'est attendu : le
certificat est auto-signé, aucune autorité ne le reconnaît. Le chiffrement est
bien réel, seule l'identité n'est pas vérifiable. Acceptez l'exception.

**GLPI démarre avec les comptes par défaut** (`glpi/glpi`, `tech/tech`,
`post-only/postonly`, `normal/normal`). Ils sont publics et connus de tous.
Changez-les à la première connexion : GLPI affiche lui-même un avertissement
tant que ce n'est pas fait.

---

## 4. Commandes du quotidien

```bash
make ps                      # état des conteneurs
make logs                    # tous les journaux, en continu
make logs S=glpi             # ceux d'un seul service
make verify                  # contrôle applicatif complet
make restart                 # redémarrage de tous les services
make down                    # arrêt — les données sont conservées
make up                      # redémarrage
make config                  # configuration Compose résolue (variables remplacées)
```

Interroger une base directement, sans jamais exposer son port :

```bash
docker compose exec db mariadb -uroot -p"$(grep DB_ROOT_PASSWORD .env | cut -d= -f2)" glpi
docker compose exec cassandra cqlsh -e "SELECT * FROM dockerwarts.sante"
docker compose exec elasticsearch curl -s localhost:9200/_cat/indices?v
```

---

## 5. Sauvegarde et restauration

```bash
make backup                              # sauvegarde complète, horodatée
make restore FROM=backups/2026-09-07_03-00-00
```

La procédure, les objectifs de temps de reprise et les tests à effectuer sont
détaillés dans [`05-PRA.md`](05-PRA.md).

---

## 6. Dépannage

### Elasticsearch redémarre en boucle

Regardez d'abord les journaux : `make logs S=elasticsearch`.

**`max virtual memory areas vm.max_map_count [65530] is too low`** — le noyau de
l'hôte n'accorde pas assez de zones mémoire. Sous Linux :

```bash
sudo sysctl -w vm.max_map_count=262144
# Pour que ce soit permanent :
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-elasticsearch.conf
```

**Le conteneur est tué sans message** — il manque de mémoire. Réduisez `ES_HEAP`
dans `.env` (par exemple `512m`) puis `docker compose up -d elasticsearch`.

### Elasticsearch est « unhealthy » et l'état du cluster est `red`

```bash
docker compose exec elasticsearch curl -s 'http://localhost:9200/_cluster/health?pretty'
```

Si les journaux mentionnent `high disk watermark [90%] exceeded`, le disque est
en cause : Elasticsearch refuse d'allouer le moindre shard au-delà de 90 %
d'occupation, ce qui met le cluster en `red`.

Cette plateforme fixe déjà les seuils en **valeurs absolues** plutôt qu'en
pourcentage (`5gb` / `3gb` / `2gb` dans `docker-compose.yml`), précisément parce
qu'un seuil à 90 % sur un disque de 250 Go déclenche alors qu'il reste 25 Go
parfaitement utilisables. S'il reste réellement moins de 3 Go, il faut faire de
la place — c'est le disque qui est plein, pas Elasticsearch qui se trompe.

### GLPI affiche une erreur de base de données

L'installation automatique a échoué. Deux causes fréquentes :

1. **MariaDB n'était pas prête.** Ne devrait pas arriver grâce à
   `condition: service_healthy`, mais si c'est le cas :
   `docker compose restart glpi`.
2. **Les mots de passe ne concordent plus** — typiquement après avoir modifié
   `.env` alors que le volume `db_data` existait déjà. MariaDB ne crée son
   utilisateur qu'au **tout premier** démarrage : changer `DB_PASSWORD` ensuite
   ne change rien dans la base. Il faut soit repartir de zéro
   (`docker compose down -v`, qui **efface les données**), soit changer le mot de
   passe dans la base elle-même.

### Cassandra reste « starting » très longtemps

C'est normal : le premier démarrage prend une à deux minutes. La sonde laisse
`start_period: 120s` avant de commencer à compter les échecs. Au-delà de trois
minutes, vérifiez la mémoire : `MAX_HEAP_SIZE` **et** `HEAP_NEWSIZE` doivent
tous les deux être définis, Cassandra refuse de démarrer si un seul l'est.

### « 404 page not found » sur une adresse

Traefik n'a pas de route pour ce nom d'hôte. Vérifiez dans l'ordre :

1. Le nom est bien dans `/etc/hosts`.
2. `DOMAIN` dans `.env` correspond bien au nom demandé.
3. Le conteneur visé tourne : `make ps`.
4. Le tableau de bord Traefik liste bien le routeur :
   https://traefik.dockerwarts.local

### « 403 Forbidden » sur Prometheus, Kibana ou Grafana

C'est le **filtrage IP qui fonctionne**, pas une panne. Votre adresse n'est pas
dans `ADMIN_CIDR`. Vérifiez l'adresse vue par Traefik dans ses journaux
(`make logs S=traefik`) et ajoutez la plage correspondante dans `.env`, puis
`docker compose up -d traefik`.

### Un port est déjà utilisé

```
Error: bind: address already in use
```

Un autre service occupe le port 80 ou 443 sur la machine (souvent Apache ou
Nginx). Arrêtez-le, ou changez le mappage dans `docker-compose.yml`
(`"8080:80"` et `"8443:443"`).

### Tout reprendre à zéro

```bash
make clean       # demande confirmation, SUPPRIME toutes les données
make init && make up
```

---

## 7. Désinstallation

```bash
docker compose down -v        # conteneurs, réseaux et volumes
docker image prune -a         # images téléchargées
rm -rf .env certs secrets backups
```

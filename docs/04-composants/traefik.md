# Traefik — point d'entrée, terminaison TLS et couche 2 du pare-feu

> Composant de la stack `edge`. Couvre `config/traefik/traefik.yml`,
> `config/traefik/dynamic.yml` et le service `traefik` de `stacks/edge.yml`.
>
> Décision structurante : [ADR-0003 — Traefik global en mode host + Keepalived sur l'hôte](../adr/0003-traefik-host-mode-keepalived.md).

## 1. Rôle dans la plateforme

Traefik est le **seul chemin d'entrée** du trafic utilisateur. Il :

1. termine le TLS pour tous les noms `*.dockerwarts.lan` (certificat wildcard de la CA interne) ;
2. route vers le bon service Swarm à partir du nom d'hôte, en découvrant les services par
   l'API Docker ;
3. applique la **couche 2 du pare-feu** (CDC §6.2) : en-têtes de sécurité, limitation de débit,
   liste blanche d'IP d'administration, authentification basique ;
4. héberge le **bouncer CrowdSec** (couche 3), qui refuse les IP bannies ;
5. produit le **journal d'accès JSON**, matière première de CrowdSec *et* du flux `logs-traefik` ;
6. expose ses métriques Prometheus et l'endpoint `/ping` sur lequel Keepalived décide qui porte
   la VIP.

## 2. Topologie Swarm

| Propriété | Valeur | Raison |
|---|---|---|
| Mode | `global` | une tâche par nœud : les trois nœuds peuvent servir le trafic, donc porter la VIP |
| Ports | `80` et `443` en **`mode: host`** | **le point le plus important du projet** — voir §3 |
| Réseaux | `edge`, `mgmt`, `crowdsec` | applications exposées, socket proxy, LAPI |
| `update_config.order` | **`stop-first`** | 80/443 sont des ports d'hôte : deux tâches ne peuvent pas les lier en même temps |
| Image | `traefik:v3.7.13@sha256:f86a2ca…` | épinglée tag + digest |

### Pourquoi `stop-first` alors que le CDC recommande `start-first` partout

`start-first` démarre la nouvelle tâche avant d'arrêter l'ancienne. Avec un port publié en
`mode: host`, la nouvelle tâche ne peut pas lier `:443` tant que l'ancienne le tient : la mise à
jour bloque. `stop-first` est donc **obligatoire** ici. La disponibilité n'en souffre pas : le
nœud en cours de mise à jour échoue son `/ping`, Keepalived déplace la VIP vers un autre nœud, et
l'utilisateur ne voit rien. C'est exactement le mécanisme testé par `tests/chaos/kill-node.sh`.

## 3. `mode: host` : le choix qui conditionne tout le reste

Swarm publie normalement un port via le **routing mesh** (`mode: ingress`) : le port est ouvert
sur les trois nœuds et le trafic est routé en interne vers une tâche quelconque. C'est pratique,
mais le mesh fait un **SNAT** : le conteneur voit l'adresse d'une passerelle overlay, jamais celle
du client.

Conséquences si l'on gardait le mesh :

- CrowdSec bannirait la passerelle overlay — c'est-à-dire tout le monde, ou personne ;
- le `rate-limit` de Traefik compterait toutes les requêtes sur une seule « IP source » ;
- l'`admin-allowlist` ne pourrait plus distinguer le poste d'administration d'Internet ;
- le journal d'accès n'aurait aucune valeur d'investigation.

`X-Forwarded-For` ne sauve rien : le SNAT a lieu **avant** Traefik, il n'y a personne pour poser
l'en-tête. D'où `mode: host` : chaque nœud écoute réellement sur 80/443, l'adresse source est
préservée, et **Keepalived** (ADR-0003) fournit le point d'entrée unique que le mesh apportait.

C'est aussi pour cela que `forwardedHeaders.trustedIPs` est **vide** dans `traefik.yml` : rien ne
se trouve devant Traefik, donc un `X-Forwarded-For` envoyé par un client est un mensonge et doit
être ignoré.

## 4. `config/traefik/traefik.yml` — configuration statique

Lue une seule fois au démarrage. La modifier impose `docker service update --force edge_traefik`
(la version du config Swarm change, ce que `scripts/deploy.sh` gère automatiquement).

### 4.1 `global`

```yaml
checkNewVersion: false
sendAnonymousUsage: false
```

La plateforme fonctionne en réseau fermé et sa version est figée par digest : un appel sortant
« nouvelle version disponible » n'apporterait rien et ajouterait une dépendance Internet au
démarrage.

### 4.2 `entryPoints`

| Entrypoint | Port | Contenu |
|---|---|---|
| `web` | 80 | redirection **permanente (308)** vers `websecure`, et `/ping` |
| `websecure` | 443 | tout le trafic applicatif, TLS `modern` |
| `metrics` | 8082 | `/metrics` Prometheus + API du dashboard, **jamais publié sur l'hôte** |

- **308 et non 301** : le 308 préserve la méthode et le corps. Un `POST` sur `http://` ne devient
  pas un `GET` silencieux — ce qui casserait un appel d'API GLPI mal configuré de façon très
  difficile à diagnostiquer.
- `/ping` est servi sur **`web`** volontairement : le contrôle de santé de Keepalived ne doit
  dépendre ni du TLS, ni de l'expiration d'un certificat, ni d'un nom à résoudre.
- Les middlewares `security-headers` et `crowdsec` sont attachés à **l'entrypoint**, pas aux
  routeurs : un service qui oublie ses labels reste protégé. Une politique de sécurité qui
  s'active par opt-in n'est pas une politique de sécurité.
- `metrics` n'est pas publié sur l'hôte : Prometheus l'atteint par l'overlay `monitoring`, et le
  dashboard passe par un routeur HTTPS normal derrière allowlist + basic-auth.

### 4.3 `providers`

**`swarm`** — découverte des services par l'API Docker :

| Clé | Valeur | Raison |
|---|---|---|
| `endpoint` | `tcp://docker-socket-proxy:2375` | **jamais** `/var/run/docker.sock` : un accès à l'API Docker est un accès root sur l'hôte (CDC §6.4) |
| `exposedByDefault` | `false` | un service n'est routé que s'il le demande explicitement. L'inverse exposerait Galera ou Elasticsearch au premier oubli |
| `network` | `edge` | par quel réseau joindre une tâche qui en a plusieurs |
| `refreshSeconds` | `10` | compromis entre réactivité au reschedule et charge sur l'API |

**`file`** — `dynamic.yml`, avec `watch: true` : les middlewares et le TLS peuvent évoluer sans
redémarrer le proxy.

### 4.4 `api` et `ping`

`insecure: false` : pas de dashboard non authentifié sur `:8080`. Le dashboard passe par le
routeur `traefik-dashboard` de `dynamic.yml`, qui empile TLS + `admin-allowlist` + `basic-auth`.

### 4.5 `metrics`

```yaml
buckets: [0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]
```

Les intervalles par défaut de Traefik sont trop grossiers pour distinguer une page GLPI à 200 ms
d'une page à 900 ms — précisément la plage qui intéresse l'exploitant. Ces intervalles rendent
l'alerte `GLPISlow` (p95 > 2 s) et le dashboard « Traefik » exploitables.

`addRoutersLabels: true` donne les métriques **par routeur**, donc par application : c'est ce qui
permet au dashboard de dire « GLPI est lent » plutôt que « Traefik est lent ».

### 4.6 `accessLog`

C'est un fichier à double lecteur, ce qui explique chacun de ses réglages :

| Réglage | Valeur | Raison |
|---|---|---|
| `filePath` | `/var/log/traefik/access.log` (bind mount hôte) | l'agent CrowdSec **du même nœud** doit pouvoir le lire ; un volume de conteneur ne serait pas partageable ainsi |
| `format` | `json` | parsé par CrowdSec et par Fluent Bit sans expression régulière fragile |
| `bufferingSize` | `100` | écritures groupées : sans cela, chaque requête est un `write()` synchrone |
| `headers.defaultMode` | `drop` puis allow-list | on ne journalise **jamais** `Authorization` ni les cookies. `User-Agent` est conservé parce que les scénarios CrowdSec s'appuient dessus |
| `ClientUsername` | `drop` | ne pas écrire le nom d'utilisateur basic-auth en clair |
| `filters.statusCodes` | `400-599` | tout ce qui échoue est journalisé intégralement |
| `filters.minDuration` | `500ms` | plus un échantillon des requêtes lentes, pour le diagnostic |

La rotation est faite par `logrotate` en **`copytruncate`** (rôle Ansible `common`) : l'inode est
préservé, donc ni CrowdSec ni Fluent Bit ne perdent le fichier.

### 4.7 `experimental.plugins`

```yaml
crowdsec:
  moduleName: github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin
  version: v1.4.6
```

Traefik télécharge et compile le plugin au démarrage (interpréteur Yaegi). Le volume nommé
`traefik_plugins` met le résultat en cache : un redémarrage fonctionne alors **sans accès
Internet**, ce qui compte lors d'une reprise après sinistre.

## 5. `config/traefik/dynamic.yml` — configuration dynamique

### 5.1 `tls`

Le certificat wildcard est déclaré à la fois dans `certificates` et comme
`stores.default.defaultCertificate` : il est donc servi pour **n'importe quel SNI**, y compris une
requête sur l'IP de la VIP. Ajouter un sous-domaine ne demande aucune modification TLS.

L'option **`modern`** :

| Réglage | Valeur | Raison |
|---|---|---|
| `minVersion` | `VersionTLS12` | TLS 1.0/1.1 sont retirés partout depuis 2020 |
| `cipherSuites` | 6 suites, toutes ECDHE + AEAD | forward secrecy obligatoire, aucun CBC. N'agit que sur TLS 1.2 (TLS 1.3 négocie ses propres suites) |
| `curvePreferences` | X25519, P-256 | les deux courbes rapides et sûres |
| `preferServerCipherSuites` | `false` | avec uniquement des suites AEAD au menu, laisser le client choisir la plus rapide pour son matériel (ChaCha20 sur mobile, AES-NI sur poste) est la recommandation actuelle |
| `sniStrict` | `false` | autorise `https://192.168.56.10/` sans SNI, utile en diagnostic |

### 5.2 Middlewares

| Middleware | Ce qu'il fait | Points d'attention |
|---|---|---|
| `security-headers` | HSTS 1 an, `X-Content-Type-Options`, `X-Frame-Options: SAMEORIGIN`, `Referrer-Policy`, `Permissions-Policy`, suppression de `Server`/`X-Powered-By` | `frameDeny: false` + `SAMEORIGIN` : GLPI et Grafana utilisent des iframes de même origine, un `DENY` casserait leurs interfaces. `browserXssFilter` est **désactivé** : l'ancien filtre XSS des navigateurs est obsolète et introduisait lui-même des vulnérabilités |
| `rate-limit` | 100 req/s en moyenne, burst 50, par IP | dimensionné pour être invisible à un humain (une page GLPI charge ~40 ressources) tout en freinant un scanner. `ipStrategy.depth: 0` = le vrai pair TCP, correct grâce à `mode: host` |
| `rate-limit-login` | 5 req/s, burst 10 | variante pour les endpoints d'authentification : une attaque par force brute est un flux lent et régulier, la moyenne compte plus que le burst |
| `admin-allowlist` | `ipAllowList` sur `ADMIN_CIDR` + `CLUSTER_CIDR` | le cluster est inclus pour que les sondes blackbox et le smoke test fonctionnent |
| `basic-auth` | htpasswd en secret Docker, `removeHeader: true` | second facteur pour Prometheus, Alertmanager et le dashboard Traefik, qui n'ont **aucune** authentification propre. `removeHeader` évite de transmettre l'en-tête `Authorization` en amont |
| `crowdsec` | plugin bouncer, **mode `stream`** | voir [`crowdsec.md`](crowdsec.md) |
| `admin-chain` | allowlist + basic-auth + rate-limit | |
| `admin-chain-noauth` | allowlist + rate-limit | pour les services qui authentifient eux-mêmes (Kibana, console MinIO) |
| `app-chain` | rate-limit | applications publiques (GLPI, Grafana) |

Les chaînes existent pour une raison précise : la protection d'une route devient **un seul label
lisible** au lieu d'une liste ordonnée à garder synchronisée entre six stacks. Une chaîne oubliée
est visible ; un `admin-allowlist` manquant au milieu d'une liste ne l'est pas.

C'est aussi ce que vérifie `scripts/lib/check-traefik.py` en CI : chaque route d'administration du
CDC §5.5 doit aboutir à `admin-allowlist`, **directement ou via une chaîne**. Une régression y est
détectée avant le déploiement.

### 5.3 Routeurs

- `traefik-dashboard` : le dashboard, derrière `admin-chain`.
- `catch-all` : `priority: 1` (la plus basse, tout vrai routeur la dépasse), service `noop` sans
  serveur. Une requête sur la VIP avec un `Host` inconnu reçoit une erreur nue au lieu de la page
  404 de Traefik, qui révélerait gratuitement quel proxy est en place.

## 6. Secrets et configs

| Objet | Type | Contenu |
|---|---|---|
| `dw_tls_cert` | secret | `fullchain.crt` (wildcard + CA) |
| `dw_tls_key` | secret | clé privée du wildcard |
| `dw_traefik_htpasswd` | secret | `admin:$5$…` (SHA-256 crypt) |
| `dw_crowdsec_bouncer_key` | secret | clé du bouncer vers la LAPI |
| `traefik_static-<hash>` | config | `traefik.yml` |
| `traefik_dynamic-<hash>` | config | `dynamic.yml` **rendu** (`${DOMAIN}`, `${ADMIN_CIDR}`, `${CLUSTER_CIDR}`) |

Les configs Swarm sont **immuables** : leur nom porte un hachage du contenu (`scripts/lib/render.sh`),
donc modifier `dynamic.yml` et relancer `make deploy-edge` suffit à faire rouler le service.
Sans ce mécanisme, l'édition serait silencieusement sans effet.

## 7. Supervision

| Élément | Détail |
|---|---|
| Endpoint | `:8082/metrics`, labels `prometheus.job=traefik`, `prometheus.port=8082` |
| Métriques clés | `traefik_entrypoint_requests_total`, `traefik_service_request_duration_seconds_bucket`, `traefik_entrypoint_open_connections`, `traefik_tls_certs_not_after` |
| Alertes | `TraefikDown` (cible absente sur un nœud, critical), `TraefikHigh5xx` (> 5 % sur 5 min, warning), `CertificateExpiringSoon` (< 14 j, warning) |
| Dashboard | « Traefik » — RPS, latences p50/p95/p99, codes HTTP par routeur, état TLS |
| Logs | journal d'exploitation en JSON (collecté comme n'importe quel conteneur) ; journal d'accès dans le flux `logs-traefik` |

## 8. Sauvegarde

**Aucune.** Traefik est entièrement sans état : sa configuration est en git, ses certificats sont
des secrets Docker regénérables par `make certs`, et le volume `traefik_plugins` n'est qu'un cache.
La reprise après sinistre est un `make deploy-edge`.

Le seul élément à conserver hors ligne est la **clé privée de la CA** (`certs/ca.key`) : sans
elle, il faudra regénérer une CA et redistribuer la confiance aux clients. Elle fait partie du
coffre au même titre que `dw_restic_password` (voir [`docs/07-PRA.md`](../07-PRA.md)).

## 9. Points d'attention

| Point | Détail |
|---|---|
| `stop-first` | obligatoire à cause des ports d'hôte ; la continuité vient de Keepalived, pas de Traefik |
| Certificat auto-signé | un navigateur avertira tant que `certs/ca.crt` n'est pas importé. `make certs` affiche la commande |
| Plugin CrowdSec | téléchargé au premier démarrage : le tout premier `make deploy-edge` a besoin d'un accès à GitHub. Ensuite le cache suffit |
| `/ping` en HTTP | volontaire : le contrôle Keepalived ne doit pas dépendre du TLS |
| `exposedByDefault: false` | ne jamais passer à `true` : cela exposerait Galera, Elasticsearch et Cassandra dès leur déploiement |
| Bascule vers ACME | pour un vrai domaine, ajouter un `certificatesResolvers` DNS-01 dans `traefik.yml` et remplacer `tls: true` par `tls.certResolver` dans les labels. Le reste ne change pas |

## 10. Basculer vers Let's Encrypt (domaine réel)

```yaml
# config/traefik/traefik.yml — à ajouter
certificatesResolvers:
  letsencrypt:
    acme:
      email: ops@example.com
      storage: /acme/acme.json      # volume nommé, sauvegardé
      # DNS-01 et non HTTP-01 : seul le DNS-01 permet un certificat *wildcard*,
      # et il ne demande pas que le port 80 soit joignable depuis Internet.
      dnsChallenge:
        provider: ovh               # ou cloudflare, gandiv5, …
        delayBeforeCheck: 30
```

Puis, dans les labels des services, remplacer `traefik.http.routers.<r>.tls: "true"` par
`traefik.http.routers.<r>.tls.certresolver: "letsencrypt"`, et fournir les identifiants du
fournisseur DNS en variables d'environnement (issues de secrets Docker). `scripts/gen-certs.sh`
devient alors inutile pour le wildcard — mais reste nécessaire pour la CA interne, qui signe
toujours les certificats de transport Elasticsearch.

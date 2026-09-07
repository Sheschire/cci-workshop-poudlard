# 03 — Sécurité et pare-feu

Le sujet demande **un pare-feu, applicatif ou non**, en laissant le choix à
l'apprenant. Ce document explique le choix retenu, ce qu'il protège
concrètement, et les autres mesures de sécurité de la plateforme.

---

## 1. Le choix : un pare-feu applicatif, Traefik

Un pare-feu réseau classique filtre des **adresses et des ports**. C'est utile,
mais sur une plateforme dockerisée où deux ports seulement sont ouverts (80 et
443), il n'a presque rien à filtrer : tout passe par HTTPS, et c'est justement
là que se trouve le risque.

Ce qu'un pare-feu réseau ne peut pas faire et qui compte ici :

- distinguer une requête vers GLPI d'une requête vers Prometheus — les deux
  arrivent sur le port 443 ;
- exiger une authentification avant d'atteindre une interface d'administration ;
- limiter le débit d'un client qui martèle une page de connexion ;
- imposer HTTPS et poser les en-têtes de sécurité.

C'est ce que fait un **pare-feu applicatif**, et c'est le rôle tenu par Traefik.
Une seconde couche, réseau celle-là, est disponible dans
[`scripts/firewall.sh`](../scripts/firewall.sh) — voir §5.

---

## 2. Ce que Traefik filtre, dans l'ordre

Toute requête traverse cette chaîne avant d'atteindre le moindre service.

```
requête
   │
   ├─ 1. port 80 ?           → redirection 301 vers HTTPS, fin
   │
   ├─ 2. terminaison TLS      TLS 1.2 minimum, suites AEAD uniquement
   │
   ├─ 3. nom d'hôte connu ?  → non : 404, la requête n'atteint aucun service
   │
   ├─ 4. filtrage IP          (interfaces d'administration seulement)
   │      adresse hors ADMIN_CIDR → 403, avant toute demande de mot de passe
   │
   ├─ 5. authentification     (interfaces d'administration seulement)
   │      pas d'identifiants  → 401
   │
   ├─ 6. limitation de débit  100 req/s, rafale 200
   │
   ├─ 7. en-têtes de sécurité posés sur la réponse
   │
   └─→ service
```

### Les trois chaînes de middlewares

Elles sont déclarées comme **labels sur le service Traefik** dans
`docker-compose.yml`, et non dans `config/traefik/dynamic.yml`. La raison est
concrète : le fournisseur « file » de Traefik ne remplace pas les variables
d'environnement, alors que Compose le fait. C'est ce qui permet de régler
`ADMIN_CIDR` dans `.env` au lieu d'éditer un fichier de configuration.

| Chaîne | Contenu | Appliquée à |
|---|---|---|
| `public-chain` | en-têtes + limitation de débit | GLPI |
| `admin-chain` | filtrage IP + authentification + en-têtes | Traefik, Prometheus, Kibana |
| `admin-chain-noauth` | filtrage IP + en-têtes | Grafana |

> **Pourquoi Grafana échappe à l'authentification Traefik.** Il a la sienne, avec
> des comptes, des rôles et des permissions par tableau de bord. Ajouter un
> second mot de passe devant n'apporterait aucune sécurité supplémentaire —
> le filtrage IP, lui, reste — et casserait ses API, utilisées par ses propres
> pages.

> **Pourquoi GLPI n'a pas de filtrage IP.** C'est l'application destinée aux
> utilisateurs finaux : la restreindre à quelques adresses la rendrait
> inutilisable. Elle a en revanche une limitation de débit, ce qui n'est pas le
> cas des interfaces d'administration — un exploitant légitime peut avoir besoin
> de rafraîchir Prometheus sans être bridé.

### Ce que le filtrage IP protège vraiment

**Prometheus n'a aucune authentification native.** Aucune. Exposé sans
protection, son interface donne à n'importe qui la topologie complète de la
plateforme, les noms de tous les conteneurs, leur consommation, et l'historique
de leurs pannes. C'est une carte détaillée offerte à qui veut la lire.

Le filtrage IP intervient **avant** l'authentification, ce qui est délibéré :
une requête venue d'ailleurs est refusée sans qu'on lui donne l'occasion de
tester des mots de passe.

`make verify` contrôle ce point pour de vrai : il envoie une requête sans
identifiants sur Prometheus et **échoue si la réponse n'est pas 401 ou 403**.

---

## 3. La segmentation réseau

C'est, techniquement, la mesure la plus solide du projet.

Le réseau `backend` est déclaré `internal: true`. Docker ne lui attache alors
**aucune passerelle par défaut**. Concrètement, un attaquant qui prendrait le
contrôle du conteneur MariaDB ou Cassandra :

- ne peut télécharger aucun outil — pas de route vers Internet ;
- ne peut exfiltrer aucune donnée vers un serveur externe ;
- ne peut joindre aucune machine du réseau local.

Ce n'est pas une règle de filtrage qu'on contourne avec assez d'astuce : c'est
**l'absence de route**. Aucune commande exécutée dans le conteneur n'y change
quoi que ce soit.

Se trouvent uniquement sur `backend`, donc totalement injoignables depuis
l'extérieur : MariaDB, Cassandra, node-exporter et cAdvisor.

**Aucun port de base de données n'est publié sur l'hôte.** Il n'y a ni
`3306:3306`, ni `9200:9200`, ni `9042:9042` dans le fichier. Pour interroger une
base, on passe par `docker compose exec`.

---

## 4. La gestion des secrets

**Règle tenue sans exception : aucun secret n'entre dans le dépôt.**

| Fichier | Contenu | Statut |
|---|---|---|
| `.env.example` | valeurs d'exemple | **versionné** |
| `.env` | mots de passe réels | ignoré par git |
| `certs/*.key` | clé privée TLS | ignoré par git |
| `secrets/users.htpasswd` | empreinte du mot de passe | ignoré par git |

`make init` produit les trois derniers. Il tire quatre mots de passe au hasard
plutôt que de laisser des `change-me` en place : un mot de passe par défaut
qu'on oublie de changer est une vulnérabilité, un mot de passe aléatoire qu'on
oublie de noter est une gêne.

Le mot de passe d'administration n'est jamais écrit en clair sur le disque :
`openssl passwd -apr1` en produit l'empreinte, et c'est elle que Traefik lit.

**Le mot de passe MariaDB ne transite jamais par la ligne de commande de
l'hôte.** Dans `backup.sh` comme dans `verify.sh`, les commandes sont écrites
entre guillemets **simples** pour que `$MARIADB_ROOT_PASSWORD` soit développé
*dans* le conteneur. Écrit entre guillemets doubles, il apparaîtrait dans la
sortie de `ps` de la machine, lisible par tout utilisateur connecté.

---

## 5. Le pare-feu réseau, seconde couche

[`scripts/firewall.sh`](../scripts/firewall.sh) est **facultatif** : la
plateforme fonctionne sans lui. Il durcit une installation réelle, sur une
machine exposée.

```bash
./scripts/firewall.sh                 # affiche les règles, ne modifie rien
sudo ./scripts/firewall.sh --appliquer
```

Il existe pour un piège précis, et très fréquent : **Docker écrit ses propres
règles DNAT en amont des chaînes d'ufw**. Un port publié par un conteneur est
donc joignable depuis l'extérieur même quand `ufw status` affiche « deny ».
Beaucoup d'administrateurs croient leur machine protégée alors qu'elle ne l'est
pas.

La seule chaîne que Docker consulte et ne réécrit jamais est `DOCKER-USER`.
C'est celle que ce script alimente : tout ce qui n'est ni du trafic établi, ni
du trafic inter-conteneurs, ni les ports 80 et 443, est rejeté.

Le script vide la chaîne avant d'écrire, pour qu'une seconde exécution ne
duplique pas les règles.

---

## 6. Les autres mesures

**Toutes les images sont épinglées à une version précise.** Jamais de `latest`.
Une infrastructure qui change toute seule au prochain `pull` n'est ni
reproductible ni auditable, et les mises à jour arrivent alors sans qu'on l'ait
décidé.

**Un seul conteneur voit le socket Docker : Traefik, en lecture seule** (`:ro`).
Il doit lire l'API pour découvrir les services ; il n'a aucune raison de pouvoir
y écrire. Un accès en écriture au socket Docker équivaut à un accès root sur la
machine — c'est la vulnérabilité la plus courante des plateformes dockerisées.

**Rien n'est exposé par défaut.** `--providers.docker.exposedByDefault=false` :
un conteneur n'est publié que s'il porte explicitement `traefik.enable=true`.
Ajouter un service ne l'expose pas par accident.

**Les journaux sont bornés** (`max-size: 10m`, `max-file: 3`). Sans limite, un
conteneur bavard remplit le disque et emporte toute la plateforme : MariaDB,
Elasticsearch et Cassandra s'arrêtent ensemble. Panne classique, et évitable en
quatre lignes.

**Chaque service a une limite mémoire.** Un service qui fuit est tué seul, au
lieu d'emporter la machine avec lui.

---

## 7. Les limites, dites franchement

**Le certificat TLS est auto-signé.** Le chiffrement est réel, mais l'identité
du serveur n'est pas vérifiable — le navigateur affiche un avertissement. En
production, on remplace le bloc `tls.stores` de
`config/traefik/dynamic.yml` par un resolver ACME :

```yaml
# docker-compose.yml, service traefik, à ajouter aux `command` :
- --certificatesresolvers.letsencrypt.acme.email=admin@exemple.fr
- --certificatesresolvers.letsencrypt.acme.storage=/certs/acme.json
- --certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web
# puis, sur chaque routeur :
#   traefik.http.routers.<nom>.tls.certresolver: "letsencrypt"
```

**La sécurité d'Elasticsearch est désactivée** (`xpack.security.enabled=false`).
C'est un choix assumé et borné : ce port n'est joignable que depuis `backend`,
qui n'a aucune route vers l'extérieur, et Kibana est protégé par la chaîne
d'administration. Activer `xpack.security` imposerait de gérer des certificats
internes et des mots de passe entre Elasticsearch et Kibana, pour une surface
d'attaque déjà nulle. Sur un cluster multi-machines, ce raisonnement ne tiendrait
plus et il faudrait l'activer.

**cAdvisor tourne en mode privilégié.** Il lit les groupes de contrôle du noyau
et n'y arrive pas autrement sur la plupart des distributions. C'est la seule
exception au principe « aucun conteneur privilégié », elle est limitée à un
service qui ne fait que lire, et qui n'est joignable depuis nulle part
(uniquement sur `backend`, sans port publié).

**GLPI démarre avec ses comptes par défaut** (`glpi/glpi`, `tech/tech`,
`post-only/postonly`, `normal/normal`), qui sont publics. Ils doivent être
changés à la première connexion. GLPI affiche lui-même un avertissement tant que
ce n'est pas fait — c'est volontairement laissé à l'exploitant plutôt
qu'automatisé, parce qu'un mot de passe changé par un script et jamais
communiqué ne vaut pas mieux.

**Il n'y a pas de détection d'intrusion.** Un outil comme CrowdSec ou fail2ban
lirait les journaux d'accès de Traefik et bannirait les adresses agressives.
C'est la première chose à ajouter si la plateforme devient réellement exposée ;
elle n'a pas été retenue ici pour tenir le périmètre « un seul
`docker-compose.yml` ».

# 01 — Architecture

Ce document décrit ce qui compose la plateforme, comment les briques
communiquent, et **pourquoi** ces outils plutôt que d'autres.

---

## 1. Vue d'ensemble

```
                        Internet / réseau local
                                  │
                          80 (→ 443) et 443
                                  │
                    ┌─────────────▼─────────────┐
                    │          TRAEFIK          │   pare-feu applicatif
                    │  TLS · filtrage IP · auth │   point d'entrée unique
                    │  limitation de débit      │
                    └─────────────┬─────────────┘
                                  │
        ┌──────────────┬──────────┴────────┬──────────────┐
        │              │                   │              │
   réseau proxy   réseau proxy        réseau proxy   réseau proxy
        │              │                   │              │
    ┌───▼───┐     ┌────▼────┐        ┌─────▼─────┐  ┌──────▼─────┐
    │ GLPI  │     │ KIBANA  │        │ PROMETHEUS│  │  GRAFANA   │
    └───┬───┘     └────┬────┘        └─────┬─────┘  └──────┬─────┘
        │              │                   │               │
════════╪══════════════╪═══════════════════╪═══════════════╪════════
        │      réseau backend — internal: true, aucune sortie
        │              │                   │               │
    ┌───▼────┐   ┌─────▼────────┐   ┌──────▼──────┐  ┌─────▼──────┐
    │MARIADB │   │ELASTICSEARCH │   │NODE-EXPORTER│  │  CADVISOR  │
    └────────┘   └──────────────┘   └─────────────┘  └────────────┘
                                    ┌─────────────┐
                                    │  CASSANDRA  │   datalake
                                    └─────────────┘
```

Dix services, deux réseaux, neuf volumes. Tout est décrit dans un seul fichier,
`docker-compose.yml`, commenté ligne à ligne.

---

## 2. Les services, un par un

### Traefik v3.7 — point d'entrée et pare-feu applicatif

C'est **le seul conteneur qui publie des ports** sur la machine : 80 et 443.
Tout le reste est joignable uniquement à travers lui.

Traefik découvre les services par les **labels** qu'ils portent. Ajouter une
application exposée, c'est ajouter quatre labels sur son service — jamais
éditer la configuration du proxy. C'est ce qui rend le fichier lisible malgré
dix services.

Il fait aussi office de pare-feu applicatif : terminaison TLS, redirection
HTTP → HTTPS, filtrage par adresse IP, authentification, limitation de débit,
en-têtes de sécurité. Le détail est dans
[`03-securite.md`](03-securite.md).

> **Pourquoi Traefik plutôt que Nginx ?** Nginx exige d'écrire un bloc `server`
> par service et de recharger la configuration à chaque changement. Traefik lit
> les labels Docker et se reconfigure seul. Sur une plateforme de dix services
> qui bougent, la différence n'est pas cosmétique : c'est ce qui évite qu'une
> configuration diverge silencieusement de la réalité.

### GLPI 10.0 — le ticketing

Outil de référence en gestion de parc et de tickets dans le monde francophone,
libre, et proposant une **image officielle qui s'auto-installe** : les cinq
variables `GLPI_DB_*` suffisent, il n'y a aucun assistant web à dérouler à la
main. Une plateforme qui se reconstruit en une commande ne peut pas dépendre de
quinze clics dans un navigateur.

GLPI est le seul service ouvert au public : c'est l'application destinée aux
utilisateurs finaux.

### MariaDB 11.4 — la base de GLPI

GLPI ne fonctionne qu'avec MySQL ou MariaDB. MariaDB est le choix recommandé
par le projet GLPI lui-même. La version 11.4 est une **LTS**, maintenue
jusqu'en 2029.

Elle vit sur le réseau `backend` : GLPI seul la joint, personne d'autre.

### Elasticsearch 8.19 — l'historisation des données

Moteur de recherche et d'indexation orienté document. C'est l'outil cité par le
sujet, et il est effectivement le standard pour conserver et interroger des
volumes de journaux ou d'événements avec des recherches en texte intégral.

Configuré en `discovery.type=single-node` : sur une machine unique, l'élection
de maître n'aurait aucun sens et bloquerait le démarrage.

> **Un mot sur l'état « yellow ».** Un nœud unique ne peut pas allouer les
> répliques de ses index — elles devraient aller sur un autre nœud, qui n'existe
> pas. L'état normal est donc `yellow`, pas `green`. La sonde de santé exige
> `yellow` : exiger `green` laisserait le service éternellement « unhealthy »
> alors qu'il fonctionne parfaitement.

### Kibana 8.19 — l'exploration

L'interface d'Elasticsearch. Sans elle, l'historisation est une boîte noire :
on y écrit sans jamais rien relire. Kibana rend les données consultables par un
humain, ce qui est la raison d'être de l'historisation.

Version strictement identique à celle d'Elasticsearch : Kibana refuse de
démarrer contre un Elasticsearch d'une autre version mineure.

### Cassandra 5.0 — le datalake

Base distribuée orientée colonnes, conçue pour absorber de très gros volumes
d'écritures et grandir par ajout de nœuds. C'est l'outil cité par le sujet, et
il correspond à ce qu'on attend d'un datalake : écritures massives, lectures par
plage temporelle, croissance horizontale.

Le schéma initial est dans [`config/cassandra/init.cql`](../config/cassandra/init.cql),
joué une fois par le service `cassandra-init`.

> **La clé de partition est la seule décision qui ne se rattrape pas.** Elle est
> ici `(source, jour)`, parce que les lectures se font toujours « une source,
> une journée ». Prendre l'identifiant de l'événement aurait donné une
> répartition parfaite… et rendu impossible toute lecture par plage. C'est
> l'erreur classique avec Cassandra, et elle impose de tout réécrire.

### Prometheus 3.13 — la collecte

Prometheus va chercher les métriques (*pull*) à intervalle fixe, plutôt que de
les recevoir. C'est ce qui lui permet de savoir qu'une source **ne répond plus** :
un système qui attend qu'on lui envoie des données ne peut pas distinguer
« tout va bien, rien à signaler » de « la source est morte ».

Quatre sources : lui-même, node-exporter, cAdvisor et Traefik. Rétention de
30 jours.

### Grafana 13 — le monitoring

L'interface de consultation. Sa source de données et son tableau de bord sont
**provisionnés depuis des fichiers versionnés** : une machine reconstruite
retrouve exactement les mêmes écrans, sans qu'on recrée quoi que ce soit à la
main.

Le tableau de bord fourni est décrit au §5.

### node-exporter et cAdvisor — les sondes

- **node-exporter** mesure la machine : processeur, mémoire, disque, charge.
- **cAdvisor** mesure chaque conteneur : processeur, mémoire, redémarrages.

Les deux ensemble répondent aux deux questions qui comptent lors d'un incident :
« la machine est-elle saturée ? » et « lequel des dix services en est la
cause ? ».

---

## 3. Les réseaux

Deux réseaux, et la séparation entre les deux est la mesure de sécurité la plus
efficace du projet.

| Réseau | Nom Docker | Sortie Internet | Qui s'y trouve |
|---|---|---|---|
| `proxy` | `dockerwarts_proxy` | oui | Traefik et les services qu'il expose |
| `backend` | `dockerwarts_backend` | **non** (`internal: true`) | bases, moteurs, sondes |

`internal: true` retire la passerelle par défaut du réseau. Un conteneur
compromis sur `backend` **ne peut joindre aucune adresse extérieure**, quoi
qu'il exécute : ni téléchargement d'outil, ni exfiltration de données. Ce n'est
pas une règle de filtrage qu'on peut contourner, c'est l'absence de route.

MariaDB, Cassandra, node-exporter et cAdvisor sont **uniquement** sur `backend` :
ils ne sont joignables ni depuis Internet ni depuis Traefik. GLPI, Kibana,
Prometheus et Grafana sont sur les deux, parce qu'ils doivent à la fois être
exposés et joindre leurs dépendances.

**Aucun port de base de données n'est publié sur l'hôte.** Pas de `3306:3306`,
pas de `9200:9200`, pas de `9042:9042`. Pour interroger MariaDB depuis la
machine, on passe par `docker compose exec`.

---

## 4. Les volumes

Tout ce qui doit survivre à `docker compose down` est dans un volume nommé.

| Volume | Contenu | Sauvegardé par |
|---|---|---|
| `db_data` | Base MariaDB (tickets, parc, utilisateurs) | `mariadb-dump` |
| `glpi_files` | Documents joints aux tickets | archive tar |
| `glpi_config` | Configuration **et clé de chiffrement** de GLPI | archive tar |
| `glpi_plugins`, `glpi_marketplace` | Extensions installées | archive tar |
| `es_data` | Index Elasticsearch **et** dépôt de snapshots | API snapshot, puis archive du seul sous-répertoire `snapshots/` |
| `cassandra_data` | Données du datalake | `nodetool snapshot` |
| `prometheus_data` | 30 jours de métriques | non sauvegardé (voir ci-dessous) |
| `grafana_data` | Comptes et préférences Grafana | archive tar |

> **Pourquoi `prometheus_data` n'est pas sauvegardé.** Les métriques sont des
> données d'observation, pas des données métier : leur perte n'empêche personne
> de travailler, et elles se reconstituent d'elles-mêmes en quelques minutes.
> Les sauvegarder représenterait le plus gros volume du lot pour la valeur la
> plus faible. Ce choix est assumé et documenté dans
> [`05-PRA.md`](05-PRA.md).

> **`glpi_config` est le volume le plus important après la base.** Il contient
> la clé de chiffrement de GLPI. Sans elle, tous les mots de passe enregistrés
> dans l'application (LDAP, SMTP, comptes d'inventaire) sont **irrécupérables**,
> même avec une base de données parfaitement restaurée.

---

## 5. Le tableau de bord

Un seul tableau de bord, `Dockerwarts — vue d'ensemble`, en quatre bandeaux.
Le parti pris est de **ne pas multiplier les écrans** : un exploitant en
incident regarde une page, pas douze.

**Disponibilité** — quatre indicateurs de synthèse (cibles répondant, CPU,
mémoire, disque) et l'historique de disponibilité de chaque source. C'est la
première chose qu'on regarde, et souvent la seule nécessaire.

**Conteneurs** — processeur et mémoire par service, part de la limite mémoire
atteinte, et nombre de redémarrages sur 15 minutes. Ces deux derniers panneaux
répondent aux pannes les plus discrètes : un conteneur tué par le noyau parce
qu'il touche *sa* limite alors que la machine a de la mémoire libre, et un
service qui redémarre en boucle en paraissant « démarré » à chaque coup d'œil.

**Trafic** — requêtes par seconde, codes de réponse HTTP empilés, et temps de
réponse médian et 95e centile. C'est la vue **côté utilisateur** : un 5xx ici
signifie une panne réelle, même quand les dix conteneurs sont `running`. La
médiane dit ce que vit l'utilisateur moyen, le 95e centile ce que vivent les
plus mal servis — les deux sont nécessaires, une moyenne seule masquerait les
deux.

Les **unités et les seuils** sont explicites : pourcentages en `percent`,
mémoire en `bytes`, débit en `reqps`, latence en `s`. Un graphe sans unité
oblige à deviner, et on devine mal en situation d'incident.

---

## 6. Ce que cette architecture ne prétend pas être

Honnêteté sur les limites, elles sont détaillées dans
[`04-haute-disponibilite.md`](04-haute-disponibilite.md) :

- **La machine hôte est un point de défaillance unique.** Un seul serveur,
  donc pas de tolérance à sa panne. Les mesures de haute disponibilité mises
  en place couvrent les pannes de *service*, pas les pannes de *machine*.
- **Chaque moteur de données tourne en un exemplaire.** MariaDB, Elasticsearch
  et Cassandra ne sont pas en cluster.
- **Le certificat TLS est auto-signé.** En production, on branche Let's Encrypt.

Ces limites sont des conséquences directes du choix « un seul `docker-compose.yml`
sur une machine », qui est le périmètre demandé. La documentation indique pour
chacune ce qu'il faudrait changer pour la lever.

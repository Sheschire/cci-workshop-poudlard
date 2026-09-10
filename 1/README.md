# Dockerwarts N°1

Infrastructure dockerisée complète pour un projet big data : ticketing,
historisation, datalake, monitoring, pare-feu, haute disponibilité et plan de
reprise d'activité.

Le tout tient dans **un seul `docker-compose.yml`** et démarre en deux
commandes.

---

## Ce qui tourne

| Rôle demandé | Outil retenu | Adresse |
|---|---|---|
| Ticketing | **GLPI 10.0** (+ MariaDB 11.4) | `https://glpi.dockerwarts.local` |
| Historisation des données | **Elasticsearch 8.19** (+ Kibana) | `https://kibana.dockerwarts.local` |
| Datalake | **Cassandra 5.0** | interne (CQL) |
| Monitoring | **Grafana 13** (+ Prometheus 3) | `https://grafana.dockerwarts.local` |
| Pare-feu | **Traefik v3** (applicatif) + `scripts/firewall.sh` (réseau) | `https://traefik.dockerwarts.local` |

Deux services de collecte complètent l'ensemble : **node-exporter** pour la
machine, **cAdvisor** pour les conteneurs.

Le raisonnement derrière chaque choix est dans
[`docs/01-architecture.md`](docs/01-architecture.md).

---

## Démarrage

Prérequis : Docker Engine 24+ avec le plugin Compose v2, 6 Go de RAM libres,
10 Go de disque.

```bash
git clone <ce-dépôt> && cd cci-workshop-poudlard

make init          # .env, certificat TLS, compte d'administration
make up            # démarre les dix services
make verify        # vérifie que chacun répond vraiment
```

`make init` affiche une ligne à ajouter à `/etc/hosts` — c'est la seule étape
qui demande `sudo`, et elle n'est nécessaire qu'une fois.

Le premier démarrage prend environ **trois minutes** : GLPI installe sa base,
Elasticsearch et Cassandra initialisent leurs volumes. `make verify` dit
exactement où en est chaque service.

La procédure détaillée, les identifiants et le dépannage sont dans
[`docs/02-installation.md`](docs/02-installation.md).

---

## Commandes courantes

```bash
make ps                            # état des conteneurs
make logs S=glpi                   # journaux d'un service
make verify                        # contrôle applicatif complet
make backup                        # sauvegarde dans backups/<horodatage>/
make restore FROM=backups/2026-…   # restauration
make down                          # arrêt (les données restent)
```

---

## Documentation

| Document | Contenu |
|---|---|
| [`docs/01-architecture.md`](docs/01-architecture.md) | Les services, les réseaux, les volumes, et pourquoi ces outils |
| [`docs/02-installation.md`](docs/02-installation.md) | Installation pas à pas, accès, dépannage |
| [`docs/03-securite.md`](docs/03-securite.md) | Le pare-feu applicatif, la segmentation réseau, les secrets |
| [`docs/04-haute-disponibilite.md`](docs/04-haute-disponibilite.md) | Les mesures de haute disponibilité et leurs limites |
| [`docs/05-PRA.md`](docs/05-PRA.md) | Plan de reprise d'activité : sauvegardes, RPO/RTO, procédures |

---

## Les principes tenus dans tout le projet

- **Aucun secret dans le dépôt.** `.env`, `certs/` et `secrets/` sont ignorés
  par git et produits par `make init`.
- **Toutes les images sont épinglées** à une version précise. Jamais de `latest` :
  une infrastructure qui change toute seule au prochain `pull` n'est pas
  reproductible.
- **Un seul conteneur voit le socket Docker** : Traefik, en lecture seule.
- **Rien n'est exposé par défaut.** Traefik n'expose un service que s'il porte
  explicitement `traefik.enable=true`.
- **Deux ports ouverts** sur la machine : 80 (redirigé vers HTTPS) et 443.

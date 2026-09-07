# Dockerwarts N°1 — Infrastructure dockerisée haute disponibilité pour projet big data

Workshop **Dockerwarts N°1** (EPSI / WIS / myDiL — difficulté ★☆☆, 80 pts).

Une infrastructure entièrement dockerisée, hautement disponible et documentée,
capable de supporter un projet big data.

| Besoin | Réponse |
|---|---|
| Ticketing | **GLPI 10** (2 replicas) sur **MariaDB Galera** (3 nœuds) via HAProxy (writer unique) |
| Historisation de données | **Elasticsearch** (3 nœuds) + **Kibana** + **Fluent Bit**, ILM, snapshots S3 |
| Monitoring | **Prometheus** (HA ×2) + **Alertmanager** (×3) + **Grafana** (×2), 12 tableaux de bord, 48 alertes, **alertes → tickets GLPI automatiques** |
| Datalake | **Cassandra 5** (3 nœuds, RF=3, `LOCAL_QUORUM`) |
| Pare-feu | 4 couches : iptables hôte, middlewares **Traefik**, **CrowdSec** (IPS + bouncer), segmentation overlay |
| Haute disponibilité | **Docker Swarm** 3 managers, **Keepalived** (VIP) + Traefik en `mode: host` |
| Sauvegarde / PRA | **MinIO** (S3) + **restic**, snapshots natifs ES et Cassandra, 11 jobs planifiés, restaurations scriptées et **exercice de reprise automatisé** |

## Démarrage rapide

```bash
cp .env.example .env                       # adapter DOMAIN, ADMIN_CIDR, VIP…
cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml
ansible-galaxy collection install -r ansible/requirements.yml

make vms provision                         # 3 VM Ubuntu 24.04 + Ansible  (~15 min)
make secrets certs                         # 41 secrets + CA interne + wildcard
make build                                 # les 4 images maison
make deploy                                # edge → data → apps → monitoring → backup
make smoke --no-backup                     # vérification de bout en bout via la VIP
make hosts | sudo tee -a /etc/hosts        # accéder depuis le navigateur
```

Pas-à-pas complet, variables et dépannage : [`docs/02-installation.md`](docs/02-installation.md).
`make help` liste toutes les cibles.

## Documentation

| Document | Contenu |
|---|---|
| [`docs/01-architecture.md`](docs/01-architecture.md) | vue d'ensemble, schémas, réseaux, stacks, dimensionnement |
| [`docs/02-installation.md`](docs/02-installation.md) | prérequis, pas-à-pas, `.env`, mode mono-nœud, dépannage |
| [`docs/03-reseau-securite.md`](docs/03-reseau-securite.md) | les 4 couches de pare-feu, matrice de flux, TLS, secrets, durcissement |
| [`docs/04-composants/`](docs/04-composants/) | **chaque** composant, chaque fichier de configuration expliqué |
| [`docs/05-monitoring.md`](docs/05-monitoring.md) | métriques, 12 tableaux de bord, les 48 alertes, boucle alerte → ticket |
| [`docs/06-haute-disponibilite.md`](docs/06-haute-disponibilite.md) | matrice de défaillance, méthode de mesure, résultats des tests chaos |
| [`docs/07-PRA.md`](docs/07-PRA.md) | RPO/RTO, 11 scénarios de sinistre, reconstruction complète, journal de tests |
| [`docs/08-exploitation.md`](docs/08-exploitation.md) | 12 runbooks : nœuds, images, secrets, certificats, ES, Cassandra, CrowdSec… |
| [`docs/adr/`](docs/adr/) | les 10 Architecture Decision Records |
| [`docs/00-cahier-des-charges.md`](docs/00-cahier-des-charges.md) | le cahier des charges d'origine |
| [`docs/PROGRESS.md`](docs/PROGRESS.md) | avancement, preuves de vérification, ce qui reste à exécuter sur les VM |

### Les composants, un par un

[`ansible`](docs/04-composants/ansible.md) ·
[`traefik`](docs/04-composants/traefik.md) ·
[`keepalived`](docs/04-composants/keepalived.md) ·
[`crowdsec`](docs/04-composants/crowdsec.md) ·
[`galera`](docs/04-composants/galera.md) ·
[`cassandra`](docs/04-composants/cassandra.md) ·
[`elasticsearch`](docs/04-composants/elasticsearch.md) ·
[`kibana`](docs/04-composants/kibana.md) ·
[`fluent-bit`](docs/04-composants/fluent-bit.md) ·
[`glpi`](docs/04-composants/glpi.md) ·
[`prometheus`](docs/04-composants/prometheus.md) ·
[`alertmanager`](docs/04-composants/alertmanager.md) ·
[`grafana`](docs/04-composants/grafana.md) ·
[`alert2glpi`](docs/04-composants/alert2glpi.md) ·
[`minio`](docs/04-composants/minio.md) ·
[`backup`](docs/04-composants/backup.md) ·
[`demo-producer`](docs/04-composants/demo-producer.md) ·
[`versions`](docs/04-composants/versions.md)

## Ce qui distingue ce dépôt

**Rien n'est déclaré sans être vérifié.** Les propriétés que la plateforme
annonce sont contrôlées automatiquement, et chaque contrôle a été éprouvé par un
test négatif — parce qu'un vérificateur qui ne détecte rien passe pour vert :

| Ce qui est promis | Ce qui le vérifie |
|---|---|
| Aucun secret dans git | `scripts/check-no-secrets.sh` (test négatif : un secret planté est détecté) |
| Un seul conteneur voit le socket Docker | `scripts/validate-stacks.sh` + `tests/smoke/network-isolation.sh` sur le cluster vivant |
| Toute image épinglée tag **et** digest | `validate-stacks.sh`, avec une liste d'exceptions écrite et justifiée |
| Durcissement sur **tous** les services | `validate-stacks.sh` (`no-new-privileges`, `cap_drop`, limites, journalisation, healthcheck) |
| Les interfaces d'administration sont protégées | `scripts/lib/check-traefik.py` + `make smoke` (un 200 sans identifiants est un **échec**) |
| Les 48 alertes se déclenchent quand il faut | 15 tests unitaires `promtool test rules` |
| Les tableaux de bord ne mentent pas | `check-grafana.py` : 155 panneaux, 0 chevauchement, 0 UID orphelin |
| Les sauvegardes sont **restaurables** | `make dr-drill` — restauration réelle, comparée à la production, puis nettoyée |
| La segmentation réseau tient | `network-isolation.sh`, avec contre-tests |
| Chaque fichier de `config/` est documenté | `scripts/check-docs-coverage.sh` |
| Le mode mono-nœud est déployable | `validate-stacks.sh` valide le fichier **réellement déployé** |

`make lint` exécute l'ensemble, et la CI aussi.

## Tests

```bash
make lint            # yamllint, ansible-lint, shellcheck, hadolint, ruff,
                     # promtool, amtool, docker stack config, couverture doc
make test-python     # 32 tests unitaires (alert2glpi, demo-producer)
make smoke           # bout en bout via la VIP
make chaos           # campagne HA : 8 scénarios, indisponibilité mesurée
make dr-drill        # exercice de reprise, production intacte
```

## Structure

```
ansible/     8 rôles idempotents : hôtes, Docker, pare-feu, NFS, Keepalived, Swarm, labels
stacks/      6 stacks Compose v3.8 + l'override mono-nœud
config/      52 fichiers de configuration, tous documentés
images/      4 images maison : cassandra, alert2glpi, backup-runner, demo-producer
scripts/     déploiement, initialisations, sauvegardes, restaurations, validations
tests/       smoke, chaos, exercice de reprise
docs/        toute la documentation, en français
```

## Licence et contexte

Projet pédagogique. Les contacts et organisations mentionnés dans
[`docs/07-PRA.md`](docs/07-PRA.md) sont fictifs.

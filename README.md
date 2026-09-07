# Dockerwarts N°1 — Infrastructure dockerisée haute disponibilité pour projet big data

Workshop **Dockerwarts N°1** (EPSI / WIS / myDiL — difficulté ★☆☆, 80 pts).

Objectif : une infrastructure entièrement dockerisée, hautement disponible et documentée, capable de supporter un projet big data :

| Besoin | Réponse |
|---|---|
| Ticketing | **GLPI 10** (2 replicas) sur **MariaDB Galera** (3 nœuds) via HAProxy |
| Historisation de données | **Elasticsearch** (3 nœuds) + **Kibana** + **Fluent Bit**, ILM, snapshots S3 |
| Monitoring | **Prometheus** (HA ×2) + **Alertmanager** (×3) + **Grafana** (×2) + exporters, alertes → tickets GLPI automatiques |
| Datalake | **Cassandra 5** (3 nœuds, RF=3) |
| Pare-feu | 4 couches : iptables hôte, middlewares **Traefik**, **CrowdSec** (IPS + bouncer), segmentation overlay |
| Haute disponibilité | **Docker Swarm** 3 managers, **Keepalived** (VIP) + Traefik global, services répliqués ou clusterisés |
| Sauvegarde / PRA | **MinIO** (S3) + **restic**, snapshots natifs ES/Cassandra, jobs planifiés, restaurations scriptées et testées (`make dr-drill`) |

## Documents

- [`docs/00-cahier-des-charges.md`](docs/00-cahier-des-charges.md) — **cahier des charges complet** : exigences, architecture, choix technologiques, spécification de chaque composant, HA, PRA, structure du dépôt, phases et critères d'acceptation.
- [`docs/adr/`](docs/adr/) — Architecture Decision Records (justification des choix structurants).
- [`docs/BRIEF_OPUS.md`](docs/BRIEF_OPUS.md) — brief de handoff pour l'agent de développement.

Les autres documents (`docs/01` → `docs/08`) sont produits pendant le développement, conformément au cahier des charges.

## Démarrage rapide (cible, une fois le projet développé)

```bash
cp .env.example .env            # adapter DOMAIN, ADMIN_CIDR, VIP…
make vms provision              # 3 VM Ubuntu 24.04 + Ansible (Docker, firewall, NFS, Keepalived, Swarm)
make secrets certs              # secrets Docker + CA interne / certificat wildcard
make deploy                     # edge → data → apps → monitoring → backup
make smoke                      # vérification de bout en bout via la VIP
```

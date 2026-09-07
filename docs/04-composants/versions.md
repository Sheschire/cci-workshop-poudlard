# Versions et images — registre de référence

> **Rôle de ce document** : registre de référence des versions figées du projet (CDC §7, §10.2,
> §6.4). Chaque image publique est épinglée **tag + digest** dans les fichiers `stacks/*.yml` et
> `images/*/Dockerfile` ; ce tableau en est la vue lisible et l'historique.
>
> **Règle de sélection** : dernière version *patch* de la version *mineure* indiquée par le CDC,
> résolue le 2026-09-07.

## Pourquoi épingler par digest

Un tag est **mutable** : `traefik:v3.7.13` peut être reconstruit et republié. Deux nœuds qui
tirent l'image à quelques jours d'intervalle exécuteraient alors deux binaires différents — ce
qui est indétectable et ingérable en production. Le digest (`@sha256:…`) désigne un contenu
immuable ; le tag reste présent parce qu'il porte l'information de version, illisible dans un
digest.

Le script `scripts/pin-digests.sh` (cible `make pin-digests`, exécuté aussi par la CI)
re-résout chaque tag et signale toute dérive. Une dérive n'est jamais corrigée en silence :
c'est le signal qu'une montée de version délibérée est à faire, à documenter ici.

```bash
make pin-digests                  # rapport de dérive
scripts/pin-digests.sh --write    # réécrit les stacks, puis relire le diff
```

---

## Edge — `stacks/edge.yml`, `stacks/registry.yml`

| Composant | Image | Version | Digest |
|---|---|---|---|
| Traefik | `traefik` | `v3.7.13` | `sha256:f86a2cab1b5c649070c49f883c743dd32d8485a56e3368c5f93b9e91f1e91259` |
| Socket proxy | `tecnativa/docker-socket-proxy` | `0.3.0` | `sha256:9e4b9e7517a6b660f2cc903a19b257b1852d5b3344794e3ea334ff00ae677ac2` |
| CrowdSec (LAPI + agents) | `crowdsecurity/crowdsec` | `v1.8.1` | `sha256:0f2523fa61ef507f15d953045cface490cc880670c62f2755ced17524107f71a` |
| whoami | `traefik/whoami` | `v1.12.0` | `sha256:c4717a8d1f0134a7444e24f881160e033991f23027c6c5a9a3f8fd22e70d1d44` |
| Registry interne | `registry` | `2.8.3` | `sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373` |

Le **plugin bouncer Traefik** (`crowdsec-bouncer-traefik-plugin`) n'est pas une image : Traefik
le télécharge au démarrage depuis GitHub selon la version déclarée dans
`config/traefik/traefik.yml` (section `experimental.plugins`). Version figée : **v1.4.6**.

## Données — `stacks/data.yml`

| Composant | Image | Version | Digest |
|---|---|---|---|
| MariaDB Galera | `mariadb` | `11.4.13` | `sha256:611a2fcc5fa7c6ceb8644c6f74b25ede004ff6c3a6b38c8f8c23d3bbf6c26430` |
| HAProxy (`db-proxy`) | `haproxy` | `2.9.15` | `sha256:81506628494800519f82caf4128cb693df21ee5f38fca467224fcff508d537de` |
| Cassandra (base de l'image maison) | `cassandra` | `5.0.9` | `sha256:d35e159439b302146f964919904f84fd3c2cebf347272b8cb8c4368c1cf200e5` |
| Elasticsearch | `docker.elastic.co/elasticsearch/elasticsearch` | `8.19.21` | ⚠️ voir ci-dessous |
| Kibana | `docker.elastic.co/kibana/kibana` | `8.19.21` | ⚠️ voir ci-dessous |
| Fluent Bit | `fluent/fluent-bit` | `3.2.10` | `sha256:d6dec000c4929a439562525728c708f6e99800d7ddc82efd6aa4f45f3a20b562` |

> ⚠️ **Digests Elasticsearch et Kibana non résolus dans la session de développement.**
> Le registre `docker.elastic.co` est refusé par la politique d'egress de l'environnement de
> développement (`403` sur `HEAD /v2/…/manifests/…`). Les deux images sont donc épinglées par
> tag seul. À exécuter **sur un nœud du cluster** (accès Internet complet) pour compléter
> l'épinglage :
>
> ```bash
> for ref in docker.elastic.co/elasticsearch/elasticsearch:8.19.21 \
>            docker.elastic.co/kibana/kibana:8.19.21; do
>   docker buildx imagetools inspect "$ref" | awk '/^Digest:/{print $2}'
> done
> # puis, depuis le poste d'administration :
> scripts/pin-digests.sh --write && git diff stacks/data.yml
> ```
>
> La version `8.19.21` est le dernier patch de la mineure `8.19`, confirmé sur le miroir
> Docker Hub (`library/elasticsearch`, `library/kibana`), qui publie les mêmes tags.

## Applications — `stacks/apps.yml`

| Composant | Image | Version | Digest |
|---|---|---|---|
| GLPI (web + cron) | `glpi/glpi` | `10.0.26` | `sha256:ecb63fd74a97bfe267b97cea0b8482ea5cb1a1d9540a5101f7cccb4fa50b16f9` |

## Supervision — `stacks/monitoring.yml`

| Composant | Image | Version | Digest |
|---|---|---|---|
| Prometheus | `prom/prometheus` | `v3.14.0` | `sha256:5ce7540c3c00ef4ab0c9d2c995c6a5b9c421f44b4a115d97a2c7af3b1c21cbb0` |
| Alertmanager | `prom/alertmanager` | `v0.28.1` | `sha256:27c475db5fb156cab31d5c18a4251ac7ed567746a2483ff264516437a39b15ba` |
| Grafana | `grafana/grafana` | `12.4.10` | `sha256:c132a683b2430fff9115a29b2a79c8ab97540cdcc90846e3c81878c778ca3596` |
| node-exporter | `prom/node-exporter` | `v1.12.1` | `sha256:1b4e4438faca4dd7e001dd445d161a4a2091b0fededa84093b3a8dfeae1f1be0` |
| cAdvisor | `gcr.io/cadvisor/cadvisor` | `v0.55.1` | `sha256:3de2bd5203120b866d74a9b283b2ffb8ec382fbf9dc321814700c6ea6f44ec57` |
| elasticsearch-exporter | `prometheuscommunity/elasticsearch-exporter` | `v1.11.0` | `sha256:a056739b095df4baaa076f0b31321394233da9a240eeada2623d1b028b7ee7a6` |
| mysqld-exporter | `prom/mysqld-exporter` | `v0.20.0` | `sha256:abed8dac117b4ae5b70757f988e44795935b9a72c3b58d720c67ba688f8cb79e` |
| blackbox-exporter | `prom/blackbox-exporter` | `v0.28.0` | `sha256:e753ff9f3fc458d02cca5eddab5a77e1c175eee484a8925ac7d524f04366c2fc` |

Cassandra n'a pas d'exporter séparé : l'agent **JMX Prometheus** est embarqué dans l'image
maison (voir ci-dessous). Le **JMX exporter javaagent** est figé à la version **1.4.0**
(`io.prometheus.jmx:jmx_prometheus_javaagent`), téléchargé depuis Maven Central au build.

## Sauvegardes — `stacks/backup.yml`

| Composant | Image | Version | Digest |
|---|---|---|---|
| MinIO | `minio/minio` | `RELEASE.2025-09-07T16-13-09Z` | `sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e` |
| MinIO client (`mc`) | `minio/mc` | `RELEASE.2025-08-13T08-35-41Z` | `sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727` |
| swarm-cronjob | `crazymax/swarm-cronjob` | `1.10.0` | `sha256:8d95f3a161838ce31f9fa23f26780ef97de84de7744da6ba37ae59b82c0516ad` |
| backup-metrics | `nginx` | `1.29.8-alpine` | `sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de` |

> **Note sur MinIO.** Le dépôt `minio/minio` n'a pas publié de nouvelle *release* communautaire
> depuis `RELEASE.2025-09-07T16-13-09Z`. L'image reste disponible, fonctionnelle et épinglable ;
> l'API S3 utilisée par le projet (buckets, politiques, versioning, `mc mirror`, repository S3
> d'Elasticsearch) est stable. Le projet la conserve donc.
> L'**alternative prévue par l'ADR-0008 et le CDC §7.7** — **Garage** (`dxflrs/garage`) — reste
> valable sans changer un seul script : même API S3, mêmes clés, même chemin restic
> (`s3:http://minio:9000/restic`). La bascule est documentée dans
> [`docs/04-composants/minio.md`](minio.md#alternative-garage).

## Images de base des images maison

| Image maison | Base | Version | Digest |
|---|---|---|---|
| `dockerwarts/cassandra` | `cassandra` | `5.0.9` | `sha256:d35e159439b302146f964919904f84fd3c2cebf347272b8cb8c4368c1cf200e5` |
| `dockerwarts/alert2glpi` | `python` | `3.12-slim` | `sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea` |
| `dockerwarts/backup-runner` | `alpine` | `3.22.5` | `sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce` |
| `dockerwarts/demo-producer` | `python` | `3.12-slim` | `sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea` |

Les images maison sont poussées dans le registry interne (`${REGISTRY}/dockerwarts/<nom>:${IMAGE_TAG}`)
par `make build`. Elles ne sont **pas** épinglées par digest dans les stacks : le digest n'existe
qu'après le `push`, et le registry interne garantit déjà que les trois nœuds tirent le même
contenu pour un tag donné (CDC §10.2). `make build` refuse d'écraser un tag existant sans
`--force`, ce qui rend le tag immuable en pratique.

## Composants installés sur l'hôte (Ansible)

Ce ne sont pas des images : ils sont installés par le rôle Ansible indiqué.

| Composant | Version | Rôle Ansible | Source |
|---|---|---|---|
| Ubuntu Server | 24.04 LTS (noble) | — | box `bento/ubuntu-24.04` |
| Docker Engine | `5:29.3.1-1~ubuntu.24.04~noble` (figé, `apt-mark hold`) | `docker` | dépôt officiel Docker |
| containerd.io | fourni par le dépôt Docker | `docker` | dépôt officiel Docker |
| Keepalived | version du dépôt Ubuntu noble | `keepalived` | Ubuntu |
| nfs-kernel-server | version du dépôt Ubuntu noble | `nfs-server` | Ubuntu |
| iptables / netfilter-persistent | version du dépôt Ubuntu noble | `firewall` | Ubuntu |
| fail2ban | version du dépôt Ubuntu noble | `common` | Ubuntu |

La version de Docker est **figée et bloquée** (`dpkg_selections: hold` + exclusion des
`unattended-upgrades`) : une montée de version du moteur sous un Swarm vivant est une décision
d'exploitation, pas un effet de bord d'`apt`. La procédure est dans
[`docs/08-exploitation.md`](../08-exploitation.md).

## Outillage du poste d'administration et de la CI

| Outil | Version | Usage |
|---|---|---|
| Vagrant + VirtualBox | ≥ 2.4 / ≥ 7.0 | `make vms` |
| Ansible | `ansible-core` ≥ 2.16 | `make provision` |
| promtool / amtool | 3.6.0 / 0.28.1 | `make lint-prom`, tests unitaires des règles |
| shellcheck | 0.10.0 | `make lint-shell` |
| hadolint | 2.12.0 | `make lint-docker` |
| yamllint | ≥ 1.35 | `make lint-yaml` |
| ansible-lint | ≥ 24 (profil `production`) | `make lint-ansible` |
| ruff | ≥ 0.6 | `make lint-python` |
| trivy | action `aquasecurity/trivy-action@0.28.0` | scan des images maison en CI |

---

## Historique des versions

| Date | Changement |
|---|---|
| 2026-09-07 | Épinglage initial de l'ensemble des images (phase 0). |

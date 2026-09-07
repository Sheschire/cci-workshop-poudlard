# ADR-0005 — MariaDB Galera + HAProxy writer unique

**Statut** : Accepté — 2026-09-07

## Contexte
GLPI et Grafana ont besoin d'une base MySQL/MariaDB. Pour la HA, la base doit survivre à la perte d'un nœud sans perte de données validées (RPO 0) et sans intervention manuelle.

## Décision
- Cluster **MariaDB 11.4 Galera** à 3 nœuds (image officielle `mariadb`, Galera intégré), réplication synchrone multi-master.
- **HAProxy** (`db-proxy`, 2 replicas) devant le cluster, avec `galera-1` en serveur principal et `galera-2/3` en `backup` : **un seul nœud reçoit les écritures** à un instant donné, bascule automatique sur perte.
- Le même cluster héberge les bases `glpi` et `grafana` (Grafana en 2 replicas exige une base partagée).

## Alternatives étudiées
- MariaDB primaire + réplica asynchrone avec bascule manuelle/Orchestrator : RPO > 0, bascule complexe.
- PostgreSQL + Patroni : excellent, mais GLPI exige MySQL/MariaDB.
- Écritures multi-master directes (DNS round-robin sur les 3 nœuds) : risque de deadlocks de certification avec GLPI ; écarté.
- Images Bitnami Galera : configuration plus simple mais politique de publication devenue incertaine ; l'image officielle est préférée.

## Conséquences
- Bootstrap et re-bootstrap après arrêt total à scripter (`galera-bootstrap.sh`, `galera-recover.sh`) et à documenter dans le PRA.
- Sauvegarde logique quotidienne (`mariadb-dump`) : suffisante pour le périmètre, les binlogs pour du PITR sont une évolution.
- `innodb_autoinc_lock_mode=2` et format ROW imposés par Galera.

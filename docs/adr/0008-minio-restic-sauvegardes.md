# ADR-0008 — MinIO + restic + snapshots natifs pour les sauvegardes

**Statut** : Accepté — 2026-09-07

## Contexte
Le PRA exige des sauvegardes automatiques, chiffrées, à rétention définie, vérifiables et restaurables, pour des composants hétérogènes (SQL, Cassandra, Elasticsearch, fichiers, TSDB).

## Décision
- Dépôt de sauvegarde **S3** fourni par **MinIO** (1 instance pinnée node3), miroir horaire optionnel vers un S3 externe (`mc mirror`) pour la copie hors site (règle 3-2-1).
- **restic** comme outil universel (chiffrement, déduplication, `forget/prune`, `check`) pour les dumps SQL, les snapshots Cassandra, les fichiers GLPI, Prometheus, CrowdSec, les exports de configuration.
- Mécanismes **natifs** quand ils existent : snapshots Elasticsearch (repository S3 + SLM), `nodetool snapshot` déclenché à distance via JMX pour Cassandra.
- Ordonnancement par **swarm-cronjob**, jobs conteneurisés, métriques de succès exposées à Prometheus (alertes `BackupTooOld`, `BackupFailed`).
- Restauration scriptée par composant et exercice automatisé `make dr-drill`.

## Alternatives étudiées
- Cron sur l'hôte + `docker exec` : simple mais hors Swarm, dépend du placement des conteneurs et expose le socket Docker.
- Medusa (Cassandra) : outil dédié robuste mais lourd à intégrer ; `nodetool snapshot` + restic suffit pour le périmètre.
- Velero : orienté Kubernetes.
- Sauvegarde brute des volumes Docker : incohérente pour des bases en fonctionnement.
- Garage / SeaweedFS à la place de MinIO : conservés comme alternative validée si l'image MinIO n'est plus maintenue ; même API S3, scripts inchangés.

## Conséquences
- MinIO est un SPOF pour le dépôt de sauvegarde (pas pour le service) ; le miroir hors site est la vraie garantie de reprise en cas de perte de node3.
- Le mot de passe restic et les clés S3 sont des secrets à conserver hors du cluster (coffre), condition sine qua non de toute restauration : rappelé dans le PRA.

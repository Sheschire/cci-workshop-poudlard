# ADR-0007 — Elasticsearch pour logs et données, pas de Loki ; HTTP interne sans TLS

**Statut** : Accepté — 2026-09-07

## Contexte
L'énoncé impose un outil d'historisation (Elasticsearch suggéré) et un monitoring clair. La stack Grafana classique associe Loki pour les logs ; ajouter Loki à côté d'Elasticsearch créerait deux systèmes d'historisation pour le même besoin.

## Décision
- **Elasticsearch** est l'unique moteur d'historisation : logs (conteneurs, Traefik, système) via **Fluent Bit**, et données métier du datalake (`datalake-events`). Cycle de vie par ILM, snapshots natifs vers MinIO.
- Grafana consulte les logs via sa datasource Elasticsearch ; **Kibana** reste disponible pour l'exploration avancée.
- Sécurité ES activée avec **TLS sur le transport** (obligatoire entre nœuds) ; l'API HTTP reste **en clair mais confinée** au réseau overlay `data`, `internal` et chiffré IPsec. Le passage en HTTPS est documenté comme option.

## Alternatives étudiées
- Loki + Promtail : plus léger, mais redondant avec ES et moins riche en recherche full-text.
- Logstash au lieu de Fluent Bit : plus lourd (JVM) sans bénéfice ici.
- OpenSearch : équivalent fonctionnel ; Elasticsearch conservé car nommé dans l'énoncé et mieux intégré à Grafana/Kibana.
- HTTPS sur l'API ES : sécurité maximale, mais gestion de certificats supplémentaire côté Fluent Bit, Kibana, Grafana, exporter, jobs ; le réseau chiffré et isolé apporte déjà la confidentialité. Compromis retenu pour la lisibilité.

## Conséquences
- Un seul cluster à exploiter et sauvegarder pour toute l'historisation.
- Le dimensionnement mémoire d'ES (1 Go de heap par nœud, 512 Mo en profil lite) est le poste le plus lourd avec Cassandra.

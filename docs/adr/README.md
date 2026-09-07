# Architecture Decision Records

Chaque décision structurante du projet est consignée ici au format ADR (contexte, décision, alternatives, conséquences). Un choix qui évolue pendant le développement donne lieu à un nouvel ADR qui remplace l'ancien (statut « Remplacé par »), jamais à une réécriture silencieuse.

| N° | Titre | Statut |
|---|---|---|
| [0001](0001-docker-swarm.md) | Docker Swarm comme orchestrateur | Accepté |
| [0002](0002-vagrant-ansible.md) | Provisioning par Vagrant + Ansible | Accepté |
| [0003](0003-traefik-host-mode-keepalived.md) | Traefik global en mode host + Keepalived sur l'hôte | Accepté |
| [0004](0004-pare-feu-quatre-couches-crowdsec.md) | Pare-feu en quatre couches, CrowdSec comme pare-feu applicatif | Accepté |
| [0005](0005-mariadb-galera-haproxy.md) | MariaDB Galera + HAProxy writer unique | Accepté |
| [0006](0006-nfs-spof-assume.md) | NFS pour les fichiers GLPI, SPOF assumé | Accepté |
| [0007](0007-elasticsearch-logs-sans-loki.md) | Elasticsearch pour logs et données, pas de Loki ; HTTP interne sans TLS | Accepté |
| [0008](0008-minio-restic-sauvegardes.md) | MinIO + restic + snapshots natifs pour les sauvegardes | Accepté |
| [0009](0009-alert2glpi.md) | Service maison alert2glpi pour la boucle alerte → ticket | Accepté |

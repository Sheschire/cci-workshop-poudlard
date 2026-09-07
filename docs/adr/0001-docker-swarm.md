# ADR-0001 — Docker Swarm comme orchestrateur

**Statut** : Accepté — 2026-09-07

## Contexte
L'énoncé demande une « infrastructure dockerisée » avec des mesures de haute disponibilité. Il faut un orchestrateur multi-nœuds capable de replanifier des services, de gérer des réseaux privés inter-nœuds, des secrets et des mises à jour progressives, sur 3 machines modestes.

## Décision
Docker Swarm, 3 nœuds tous managers (quorum Raft 2/3), stacks Compose v3 déployées par `docker stack deploy`.

## Alternatives étudiées
- **Kubernetes (k3s)** : plus riche (operators Cassandra/ES, StatefulSets, CSI), mais une couche d'abstraction supplémentaire, une consommation mémoire notable sur 3 VM de 4–6 Go, et un vocabulaire qui s'éloigne de « dockerisé ». Disproportionné pour le périmètre.
- **Docker Compose sur un hôte unique** : pas de HA réelle (perte de l'hôte = perte totale). Conservé uniquement comme mode de développement (`make single`, sur un Swarm mono-nœud pour garder les mêmes stacks).
- **Nomad** : crédible mais moins courant, écosystème plus restreint pour ce type de stack.

## Conséquences
- Les clusters stateful (Galera, Cassandra, ES) sont modélisés par un service Swarm par membre, pinné par label de nœud, avec un volume local : Swarm n'a pas de StatefulSet.
- Découverte de services Prometheus et Traefik via l'API Docker, exposée uniquement par un proxy de socket en lecture seule.
- Les jobs planifiés reposent sur swarm-cronjob (pas de CronJob natif).
- Un Swarm de 3 managers tolère la perte d'un nœud ; la perte de deux nœuds impose `--force-new-cluster` (procédure dans le PRA).

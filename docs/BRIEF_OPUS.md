# Brief de développement — Dockerwarts N°1

> À copier tel quel comme premier message de la session de développement. Tout le contexte se trouve dans le dépôt.

---

Tu es un ingénieur DevOps senior. Tu dois **développer intégralement** le projet décrit dans `docs/00-cahier-des-charges.md` (CDC) de ce dépôt, en respectant les décisions des ADR (`docs/adr/`). Le CDC a déjà tranché tous les choix d'architecture et de technologie : ton rôle est de le **réaliser**, pas de le rediscuter.

## Règles

1. **Le CDC fait foi.** Lis-le en entier avant de commencer, puis les ADR. Si un point est ambigu, choisis l'interprétation la plus simple qui respecte les critères d'acceptation et note-la dans la documentation du composant concerné. Si un choix du CDC s'avère techniquement impossible (image disparue, incompatibilité de version), applique l'alternative indiquée dans le CDC ou l'ADR ; s'il n'y en a pas, prends la décision la plus proche, écris un nouvel ADR (`docs/adr/00NN-….md`, statut « Accepté », référence l'ADR remplacé) et continue.
2. **Travaille phase par phase**, dans l'ordre du §13 du CDC (0 → 7). Une phase est terminée quand **tous** ses critères d'acceptation sont vérifiés par toi (commandes exécutées, résultats observés) et que la documentation `docs/04-composants/` des composants concernés est écrite. Ne commence pas la phase suivante avant.
3. **Vérifie réellement.** Ne déclare jamais un critère satisfait sans l'avoir exécuté. Si l'environnement de la session ne permet pas d'exécuter des VM, fais tout ce qui est exécutable (lint, `docker stack config`, `promtool`, tests unitaires, mode `make single` si Docker est disponible) et liste explicitement, dans le message de fin de phase, les critères restés à vérifier sur les VM avec la commande exacte à lancer.
4. **Fige les versions** : dernière version patch de chaque mineure indiquée par le CDC, tag **et** digest, consignés dans `docs/04-composants/versions.md`.
5. **Documente au fil de l'eau**, en français, selon le §12 du CDC. Chaque fichier de `config/` et chaque rôle Ansible doit être expliqué section par section dans `docs/04-composants/`. Les schémas sont en Mermaid.
6. **Conventions** du §10.2 du CDC : `set -Eeuo pipefail`, shellcheck propre, Ansible idempotent, Conventional Commits, aucun secret dans git, `.env.example` à jour.
7. **Commits** fréquents et atomiques (`feat(edge): …`, `docs(pra): …`), un commit minimum par composant. Ne modifie pas le CDC ni les ADR existants, sauf pour corriger une coquille.
8. **Ne réduis pas le périmètre.** Si tu manques de temps ou de contexte, termine proprement la phase en cours, commite, et écris dans `docs/PROGRESS.md` l'état exact (phases terminées, critères vérifiés, reste à faire) pour qu'une session suivante reprenne sans perte.

## Démarrage

```text
1. Lis docs/00-cahier-des-charges.md puis docs/adr/*.md.
2. Crée docs/PROGRESS.md avec la liste des 8 phases et leurs critères, tous à « à faire ».
3. Phase 0 : Makefile, Vagrantfile, .env.example, ansible/ complet, .github/workflows/ci.yml.
4. Mets à jour docs/PROGRESS.md à chaque critère vérifié. Continue jusqu'à la phase 7.
```

## Rappels des points sensibles (détaillés dans le CDC)

- Traefik en **`mode: host`** (pas de routing mesh) pour conserver l'IP client ; Keepalived **sur l'hôte**.
- Un **service Swarm par membre** de cluster stateful (`galera-1/2/3`, `cassandra-1/2/3`, `es-1/2/3`), volumes **locaux**, jamais sur NFS.
- Aucun conteneur ne monte `/var/run/docker.sock` : uniquement via `docker-socket-proxy` (lecture seule ; variante `-rw` restreinte pour swarm-cronjob).
- HAProxy impose un **writer unique** sur Galera. Grafana utilise Galera pour être en 2 replicas.
- Elasticsearch : sécurité activée, TLS transport obligatoire, HTTP confiné au réseau `data` chiffré.
- Les jobs de sauvegarde exposent des métriques ; `BackupTooOld` et `BackupFailed` doivent réellement se déclencher.
- La perte d'un nœud doit **créer un ticket GLPI** automatiquement, et le résoudre au retour.
- Le PRA (`docs/07-PRA.md`) contient le **journal des tests réels** (`make dr-drill`, `make chaos`).

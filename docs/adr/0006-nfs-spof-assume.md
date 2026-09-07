# ADR-0006 — NFS pour les fichiers GLPI, SPOF assumé

**Statut** : Accepté — 2026-09-07

## Contexte
GLPI stocke les documents joints, la configuration et les plugins sur le système de fichiers. Avec 2 replicas web répartis sur 2 nœuds, ce répertoire doit être partagé. C'est le **seul** besoin de stockage partagé de la plateforme : toutes les bases de données utilisent des volumes locaux répliqués par leur propre mécanisme.

## Décision
Export **NFSv4** depuis node1 (rôle Ansible `nfs-server`), monté par les services GLPI via des volumes Docker `type: nfs`. Le SPOF est **explicitement assumé** et couvert par le PRA : sauvegarde restic quotidienne du répertoire, procédure de bascule de l'export sur un autre nœud (RTO 30 min), et supervision (`NodeDown` node1 → ticket).

## Alternatives étudiées
- **GlusterFS répliqué sur les 3 nœuds** : supprime le SPOF mais ajoute un système distribué à exploiter, gourmand et fragile sur de petites VM ; disproportionné pour quelques centaines de Mo de pièces jointes.
- **Ceph** : encore plus lourd.
- **GLPI en 1 replica avec volume local et reschedule** : supprime le partage mais impose alors de perdre les fichiers à la perte du nœud, ou de les mettre sur NFS de toute façon.
- **Stockage objet (S3) pour GLPI** : non supporté nativement par GLPI 10.
- **NFS managé du cloud** : recommandé en production réelle ; noté comme évolution.

## Conséquences
- En cas de perte de node1, GLPI reste accessible (base en Galera) mais les documents sont indisponibles jusqu'à la bascule NFS.
- Le dossier `docs/07-PRA.md` contient la procédure détaillée et les mesures de RTO.
- Le choix est présenté honnêtement dans la documentation comme un compromis mesuré, avec la voie d'évolution.

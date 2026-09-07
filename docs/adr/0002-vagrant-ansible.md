# ADR-0002 — Provisioning par Vagrant + Ansible

**Statut** : Accepté — 2026-09-07

## Contexte
La plateforme doit être reproductible de zéro, sur des VM locales pour le workshop comme sur des VM cloud. La configuration hôte (Docker, pare-feu, NFS, Keepalived, Swarm) doit être documentée et versionnée.

## Décision
- **Vagrant + VirtualBox** crée les 3 VM Ubuntu 24.04 (réseau host-only `192.168.56.0/24`).
- **Ansible** (playbook `site.yml`, rôles idempotents) configure les hôtes et initialise le Swarm. L'inventaire est le seul point de couplage : 3 hôtes SSH quelconques fonctionnent.

## Alternatives étudiées
- Scripts shell cloud-init seuls : moins lisibles, non idempotents, difficiles à documenter.
- Terraform : utile pour du cloud, inutile pour VirtualBox ; pourra s'ajouter devant Ansible sans rien changer.
- Multipass : plus simple sur Apple Silicon mais réseau moins contrôlable ; laissé en alternative documentée.

## Conséquences
- Tout ce qui touche l'hôte (iptables, Keepalived, NFS, sysctl, `daemon.json`) est du code Ansible commenté, donc documentable ligne par ligne.
- Le remplacement d'un nœud (PRA) est un `ansible-playbook node-replace.yml --limit nodeX`.
- Prérequis sur le poste d'administration : VirtualBox, Vagrant, Ansible, make, Docker CLI.

# ADR-0003 — Traefik global en mode host + Keepalived sur l'hôte

**Statut** : Accepté — 2026-09-07

## Contexte
Il faut un point d'entrée unique et hautement disponible, et CrowdSec doit voir l'IP réelle des clients. Le routing mesh de Swarm (mode `ingress`) publie les ports sur tous les nœuds mais **masque l'adresse source** (SNAT), ce qui rend le bannissement par IP inopérant.

## Décision
- Traefik en service **global** (une tâche par nœud), ports 80/443 publiés en **`mode: host`** : chaque nœud écoute directement, l'IP source est préservée.
- **Keepalived installé sur l'hôte** (rôle Ansible) porte une VIP `192.168.56.10` en VRRP avec un script de vérification du `/ping` Traefik local : la VIP ne se pose que sur un nœud dont Traefik est sain.

## Alternatives étudiées
- Routing mesh + `X-Forwarded-For` : impossible, le SNAT intervient avant Traefik.
- Keepalived en conteneur (`network_mode: host`, `NET_ADMIN`) : fonctionne, mais un conteneur privilégié qui manipule les interfaces de l'hôte est moins propre qu'un service système, et sa vie dépend de Docker, qu'il est censé surveiller.
- DNS round-robin sur les 3 IP : pas de bascule fiable côté client.
- Load balancer externe (HAProxy sur une 4e VM) : ajoute une machine et un nouveau SPOF.

## Conséquences
- Un seul point d'entrée à documenter côté DNS/hosts.
- Bascule mesurée < 5 s lors de la perte d'un nœud (test `kill-node.sh`).
- Keepalived est le seul composant non dockerisé avec le pare-feu et le NFS : cohérent, ce sont des fonctions d'hôte.

# ADR-0009 — Service maison alert2glpi pour la boucle alerte → ticket

**Statut** : Accepté — 2026-09-07

## Contexte
Le monitoring doit déboucher sur une action. Relier Alertmanager au ticketing démontre une boucle d'incident complète et rend le monitoring « clair » au sens de l'énoncé : chaque alerte critique devient un ticket assigné et traçable.

## Décision
Un micro-service **alert2glpi** (Python 3.12, FastAPI, ~150 lignes) reçoit le webhook Alertmanager, crée un ticket GLPI par alerte (dédupliqué par `fingerprint` inscrit dans le titre), y ajoute un suivi et le résout automatiquement quand l'alerte passe en `resolved`. Tests unitaires avec API mockée.

## Alternatives étudiées
- Plugin GLPI de réception d'e-mails (Alertmanager → SMTP → collecteur GLPI) : fonctionne mais dépend d'un serveur mail, sans déduplication ni résolution automatique.
- Outils tiers (n8n, Node-RED) : puissants mais un composant de plus, non nécessaire pour un mapping simple.
- Grafana Alerting vers GLPI : pas de récepteur GLPI natif ; Alertmanager reste la source unique d'alertes.

## Conséquences
- Un utilisateur et des tokens API GLPI dédiés, générés à l'initialisation.
- Le service expose ses propres métriques (tickets créés/résolus, erreurs API) et est lui-même supervisé.
- Comportement démontré dans les tests HA : la perte d'un nœud crée un ticket `NodeDown`, résolu au retour du nœud.

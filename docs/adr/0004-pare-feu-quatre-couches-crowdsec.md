# ADR-0004 — Pare-feu en quatre couches, CrowdSec comme pare-feu applicatif

**Statut** : Accepté — 2026-09-07

## Contexte
L'énoncé laisse le choix « applicatif ou non » et évalue la pertinence. Une plateforme exposant des interfaces web (GLPI, Grafana, Kibana) et hébergeant des données a besoin à la fois d'un filtrage réseau et d'une protection contre les attaques HTTP (brute force, scans, exploitation de CVE).

## Décision
Défense en profondeur :
1. **Hôte** : iptables (backend nftables) géré par Ansible, `INPUT DROP`, chaîne `DOCKER-USER` pour filtrer les ports publiés par Docker (qui contourne sinon les règles `INPUT`).
2. **Edge** : middlewares Traefik (TLS obligatoire, en-têtes de sécurité, rate-limit, allowlist IP des interfaces d'administration, basic-auth).
3. **Applicatif** : **CrowdSec** (agents lisant les logs Traefik et SSH, LAPI centrale, bouncer Traefik en mode stream) : détection comportementale et bannissement automatique, alimenté par la réputation communautaire.
4. **Segmentation** : réseaux overlay `internal`, réseau `data` chiffré, aucun port de base de données publié, durcissement des conteneurs.

## Alternatives étudiées
- **OPNsense/pfSense en VM** : pare-feu réseau complet mais hors périmètre « dockerisé », lourd, et sans protection applicative.
- **ModSecurity + OWASP CRS** (WAF) : protection applicative par signatures, très bruyant (faux positifs sur GLPI/Grafana) et coûteux à régler ; CrowdSec apporte la dimension comportementale et le bannissement avec moins de réglages. Peut être ajouté plus tard devant GLPI.
- **fail2ban** seul : mono-hôte, pas de partage des décisions entre nœuds, pas de scénarios HTTP riches. Conservé uniquement pour SSH sur l'hôte.
- **ufw** : ne gère pas correctement `DOCKER-USER` ; règles iptables explicites préférées.

## Conséquences
- Le pare-feu hôte reste hors Docker : c'est nécessaire (il doit filtrer avant le moteur).
- Les tests d'acceptation incluent un bannissement effectif (`cscli decisions add`, brute force GLPI).
- La LAPI est un service unique ; le bouncer en cache stream maintient la protection pendant sa replanification.

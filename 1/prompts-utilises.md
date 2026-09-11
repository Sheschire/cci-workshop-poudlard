# Prompts utilisés - Défi 1 : Dockerwarts

## Description du défi
Infrastructure dockerisée complète pour un projet big data : ticketing, historisation, datalake, monitoring, pare-feu, haute disponibilité et plan de reprise d'activité.

---

## Prompt 1 : Analyse du sujet et conception de l'architecture

> Voici le sujet du défi en PDF. L'objectif est de créer une infrastructure Docker complète incluant :
> - Un système de ticketing
> - Une solution d'historisation des données
> - Un datalake
> - Un système de monitoring
> - Un pare-feu applicatif
> - De la haute disponibilité
> - Un plan de reprise d'activité
>
> Résous l'exercice sans faire trop complexe. C'est un projet étudiant et ce n'est pas à destination d'une production d'entreprise. Propose une architecture avec des outils open-source adaptés et un docker-compose.yml unique.

---

## Prompt 2 : Implémentation des services

> Continue avec l'implémentation du docker-compose.yml. Utilise :
> - GLPI pour le ticketing
> - Elasticsearch + Kibana pour l'historisation
> - Cassandra pour le datalake
> - Grafana + Prometheus pour le monitoring
> - Traefik comme reverse proxy / pare-feu applicatif
>
> Reste simple et fonctionnel.

---

## Prompt 3 : Documentation et scripts

> Ajoute la documentation nécessaire :
> - Un README clair avec les instructions de démarrage
> - Les docs d'architecture, installation, sécurité, HA et PRA
> - Un Makefile pour simplifier les commandes
> - Les scripts d'initialisation et de sauvegarde

---

## Approche générale

Le projet a été réalisé en favorisant :
- La simplicité d'utilisation (2 commandes pour démarrer)
- Des images Docker épinglées à des versions précises
- Aucun secret dans le dépôt Git
- Une documentation complète mais concise

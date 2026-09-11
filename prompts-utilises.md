# Prompts utilisés - Workshop Poudlard

Récapitulatif des prompts utilisés pour générer les rendus des différents défis.

---

# Défi 1 : Dockerwarts

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

---
---

# Défi 11 : Accompagnement au changement

## Description du défi
Scénario d'accompagnement au changement pour le projet "Poudlard Connect" - la transformation numérique de Poudlard.

---

## Prompt principal

> Voici le sujet du défi en PDF. Il s'agit de rédiger un scénario complet d'accompagnement au changement pour un projet de transformation numérique à Poudlard.
>
> Le projet "Poudlard Connect" vise à remplacer les parchemins et hiboux par une plateforme numérique unique.
>
> Résous l'exercice sans faire trop complexe. C'est un projet étudiant et ce n'est pas à destination d'une production d'entreprise.
>
> Le document doit inclure :
> - Le contexte et la transformation choisie
> - L'analyse des parties prenantes
> - La courbe de Kübler-Ross appliquée au projet
> - Le framework ADKAR
> - Un plan de communication
> - Le dispositif d'accompagnement
> - Les risques et parades
> - Les indicateurs de réussite
>
> Adopte le point de vue du Pr. Filius Flitwick en tant que Change Manager du projet.

---

## Approche générale

Le document a été structuré de manière académique tout en restant ancré dans l'univers Harry Potter :
- Utilisation de personnages reconnaissables (McGonagall, Rusard, Mme Pomfresh)
- Application rigoureuse des méthodologies de conduite du changement
- Exemples concrets et réalistes dans le contexte magique
- Focus sur l'aspect humain plutôt que technique

---
---

# Défi 14 : La Boîte Magique de Severus Rogue

## Description du défi
Outil CLI cross-platform en C++ pour automatiser les opérations git (add, commit, push).

---

## Prompt principal

> Voici le sujet du défi en PDF. L'objectif est de créer un outil en ligne de commande qui automatise les opérations Git courantes : add, commit et push.
>
> Résous l'exercice sans faire trop complexe. C'est un projet étudiant et ce n'est pas à destination d'une production d'entreprise.
>
> Contraintes :
> - Doit être cross-platform (Linux, macOS, Windows)
> - Utiliser C++ avec CMake pour la compilation
> - Mode interactif et mode avec arguments
> - Affichage coloré du statut git

---

## Prompt complémentaire

> Ajoute les fonctionnalités suivantes :
> - Option --pull pour synchroniser avant de push
> - Option --no-push pour ne pas push après le commit
> - Génération automatique du message de commit si non spécifié
> - Détection de la branche courante
>
> Garde le code simple et lisible.

---

## Approche générale

Le projet utilise :
- CMake pour la portabilité de la compilation
- C++17 pour les fonctionnalités modernes
- Appels système à git via popen/system
- Codes ANSI pour les couleurs (avec détection Windows)

---
---

# Défi 15 : Hedwige

## Description du défi
Application web pour remplacer Hedwige - Gestion des emails, OneDrive et Teams via Microsoft Graph API.

---

## Prompt 1 : Architecture et setup

> Voici le sujet du défi en PDF. L'objectif est de créer une application web qui utilise les APIs Microsoft Graph pour gérer :
> - Les emails (lecture, envoi, suppression)
> - OneDrive (navigation, upload, download)
> - Teams (équipes, canaux, messages)
>
> Résous l'exercice sans faire trop complexe. C'est un projet étudiant et ce n'est pas à destination d'une production d'entreprise.
>
> Stack souhaitée :
> - Backend : Node.js + Express + TypeScript
> - Frontend : Next.js + React
> - Auth : MSAL (Microsoft Authentication Library)

---

## Prompt 2 : Backend API

> Implémente le backend avec les routes suivantes :
> - /auth/* pour l'authentification OAuth
> - /mail/* pour les opérations email
> - /onedrive/* pour les fichiers
> - /teams/* pour Teams
>
> Utilise des services séparés pour chaque domaine.

---

## Prompt 3 : Frontend

> Crée le frontend Next.js avec :
> - Une page de connexion
> - Un dashboard avec navigation entre Mail, OneDrive et Teams
> - Des composants réutilisables pour l'affichage des données
> - TailwindCSS pour le styling

---

## Approche générale

Le projet suit une architecture classique :
- Séparation backend/frontend
- Authentification OAuth 2.0 avec MSAL
- API RESTful vers Microsoft Graph
- Interface moderne et responsive

---
---

# Défi 22 : Le Procès de J.K. Rowling

## Description du défi
Visualisations de données humoristiques sur la saga Harry Potter.

---

## Prompt principal

> Voici le sujet du défi en PDF. L'objectif est de créer des visualisations de données amusantes analysant la saga Harry Potter sous un angle humoristique.
>
> Résous l'exercice sans faire trop complexe. C'est un projet étudiant et ce n'est pas à destination d'une production d'entreprise.
>
> Idées de métriques à visualiser :
> - Nombre de fois où la cicatrice de Harry lui fait mal par livre
> - Fréquence des "Mais" d'Hermione
> - Interventions de Dumbledore (puppet master)
> - Moments mystérieux de Rogue
> - Actes répréhensibles commis dans ces "livres pour enfants"
>
> Utilise Python avec matplotlib et plotly pour des graphiques statiques et interactifs.

---

## Prompt complémentaire

> Ajoute :
> - Une heatmap normalisée par 100 pages
> - Un dashboard interactif HTML avec Plotly
> - Un mode CLI avec options (--stats, --all)
> - Une méthodologie documentée pour les estimations
>
> Structure le projet proprement avec des modules séparés pour les données et les visualisations.

---

## Approche générale

Le projet combine :
- Des données réelles (nombre de mots par livre)
- Des estimations humoristiques mais plausibles
- Différents types de graphiques (bar, pie, heatmap, stacked)
- Un dashboard interactif pour l'exploration
- Un disclaimer sur le caractère humoristique de l'analyse

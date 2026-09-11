# Prompts utilisés - Défi 15 : Hedwige

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

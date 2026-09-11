# Hedwige

Application web pour remplacer Hedwige - Gestion des emails, OneDrive et Teams via Microsoft Graph API.

## Fonctionnalites

### Email (Microsoft Graph Mail API)
- Lire la boite de reception
- Envoyer des emails
- Marquer comme lu
- Supprimer des messages

### OneDrive (Microsoft Graph Files API)
- Naviguer dans les fichiers
- Telecharger des fichiers
- Uploader des fichiers (< 4MB)
- Creer des dossiers
- Supprimer des fichiers/dossiers

### Teams (Microsoft Graph Teams API)
- Voir les equipes et canaux
- Lire les messages des canaux
- Voir les conversations privees
- Lire les messages de chat

## Stack technique

| Composant | Technologie |
|-----------|-------------|
| Backend | Node.js + Express + TypeScript |
| Frontend | Next.js 14 + React 18 |
| Auth | MSAL (Microsoft Authentication Library) |
| API | Microsoft Graph API |
| Styling | TailwindCSS |
| Tests | Jest |
| State | TanStack Query (React Query) |

## Prerequis

- Node.js 18+
- npm ou yarn
- Un compte Microsoft (personnel ou Office 365)
- Une application enregistree dans Azure AD (voir [Guide de configuration Azure](docs/setup-azure.md))

## Installation

1. **Cloner et installer les dependances**

```bash
cd 15
npm install
cd backend && npm install
cd ../frontend && npm install
cd ..
```

2. **Configurer les variables d'environnement**

Copier le fichier `.env.example` vers `.env` et remplir les valeurs :

```bash
cp .env.example .env
```

Editer `.env` avec vos identifiants Azure AD :

```env
AZURE_CLIENT_ID=votre-client-id
AZURE_CLIENT_SECRET=votre-client-secret
AZURE_TENANT_ID=common
REDIRECT_URI=http://localhost:3001/auth/callback
FRONTEND_URL=http://localhost:3000
SESSION_SECRET=une-cle-secrete-aleatoire
```

3. **Demarrer l'application**

```bash
# Terminal 1 - Backend (port 3001)
cd backend && npm run dev

# Terminal 2 - Frontend (port 3000)
cd frontend && npm run dev
```

Ou en une commande depuis la racine :

```bash
npm run dev
```

4. **Ouvrir l'application**

Naviguer vers http://localhost:3000

## Tests

```bash
# Tous les tests
npm test

# Backend uniquement
cd backend && npm test

# Frontend uniquement
cd frontend && npm test
```

## Structure du projet

```
15/
├── README.md
├── package.json
├── .env.example
├── backend/
│   ├── src/
│   │   ├── index.ts              # Point d'entree Express
│   │   ├── config/auth.ts        # Configuration MSAL
│   │   ├── routes/               # Routes API
│   │   ├── services/             # Services Microsoft Graph
│   │   └── middleware/           # Middlewares (auth)
│   └── tests/                    # Tests Jest
├── frontend/
│   ├── src/
│   │   ├── app/                  # Pages Next.js
│   │   ├── components/           # Composants React
│   │   └── lib/api.ts            # Client API
│   └── tests/                    # Tests Jest
└── docs/
    └── setup-azure.md            # Guide configuration Azure
```

## API Endpoints

### Auth
- `GET /auth/login` - Redirection vers login Microsoft
- `GET /auth/callback` - Callback OAuth
- `GET /auth/logout` - Deconnexion
- `GET /auth/status` - Statut d'authentification

### Mail
- `GET /mail/inbox` - Boite de reception
- `GET /mail/sent` - Messages envoyes
- `GET /mail/message/:id` - Detail d'un message
- `POST /mail/send` - Envoyer un email
- `PATCH /mail/message/:id/read` - Marquer comme lu
- `DELETE /mail/message/:id` - Supprimer

### OneDrive
- `GET /onedrive/files` - Liste des fichiers
- `GET /onedrive/item/:id` - Detail d'un item
- `GET /onedrive/download/:id` - URL de telechargement
- `POST /onedrive/upload` - Upload un fichier
- `POST /onedrive/folder` - Creer un dossier
- `DELETE /onedrive/item/:id` - Supprimer

### Teams
- `GET /teams` - Liste des equipes
- `GET /teams/:teamId/channels` - Canaux d'une equipe
- `GET /teams/:teamId/channels/:channelId/messages` - Messages d'un canal
- `GET /teams/chats` - Conversations
- `GET /teams/chats/:chatId/messages` - Messages d'un chat

## Notes

- **Authentification** : L'application utilise le flux OAuth 2.0 Authorization Code avec MSAL
- **Tokens** : Les tokens sont stockes en session cote serveur
- **Scopes Teams** : Certains scopes Teams necessitent un admin consent
- **Upload** : Limite a 4MB pour l'upload simple (sans upload par chunks)

## Licence

Projet educatif - CCI Workshop Poudlard

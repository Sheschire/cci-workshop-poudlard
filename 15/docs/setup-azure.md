# Guide de configuration Azure AD

Ce guide explique comment configurer une application dans Azure Active Directory pour utiliser Hedwige.

## Prerequis

- Un compte Microsoft (personnel ou Office 365)
- Acces au portail Azure : https://portal.azure.com

## Etape 1 : Creer une App Registration

1. Connectez-vous au [Portail Azure](https://portal.azure.com)

2. Recherchez **"Azure Active Directory"** dans la barre de recherche

3. Dans le menu de gauche, cliquez sur **"App registrations"**

4. Cliquez sur **"+ New registration"**

5. Remplissez le formulaire :
   - **Name** : `Hedwige App`
   - **Supported account types** : Selectionnez **"Accounts in any organizational directory and personal Microsoft accounts"**
   - **Redirect URI** :
     - Type : `Web`
     - URL : `http://localhost:3001/auth/callback`

6. Cliquez sur **"Register"**

## Etape 2 : Configurer les permissions API

1. Dans votre application nouvellement creee, allez dans **"API permissions"**

2. Cliquez sur **"+ Add a permission"**

3. Selectionnez **"Microsoft Graph"**

4. Selectionnez **"Delegated permissions"**

5. Recherchez et selectionnez les permissions suivantes :

### Permissions Email
- `Mail.Read` - Lire les emails de l'utilisateur
- `Mail.Send` - Envoyer des emails

### Permissions OneDrive
- `Files.Read` - Lire les fichiers
- `Files.ReadWrite` - Lire et ecrire les fichiers

### Permissions Teams
- `Chat.Read` - Lire les messages de chat
- `ChannelMessage.Read.All` - Lire les messages des canaux (necessite admin consent)

### Permission de base
- `User.Read` - Lire le profil utilisateur (devrait etre deja ajoute)

6. Cliquez sur **"Add permissions"**

> **Note** : La permission `ChannelMessage.Read.All` necessite le consentement d'un administrateur. Si vous n'avez pas acces admin, vous pouvez l'omettre mais la lecture des messages de canaux Teams ne fonctionnera pas.

## Etape 3 : Creer un Client Secret

1. Dans votre application, allez dans **"Certificates & secrets"**

2. Dans la section **"Client secrets"**, cliquez sur **"+ New client secret"**

3. Remplissez :
   - **Description** : `Hedwige Secret`
   - **Expires** : Choisissez une duree (ex: 12 mois)

4. Cliquez sur **"Add"**

5. **IMPORTANT** : Copiez immediatement la valeur du secret (colonne "Value"). Elle ne sera plus visible apres avoir quitte cette page.

## Etape 4 : Recuperer les identifiants

Retournez a la page **"Overview"** de votre application et notez :

- **Application (client) ID** : C'est votre `AZURE_CLIENT_ID`
- **Directory (tenant) ID** : C'est votre `AZURE_TENANT_ID` (ou utilisez `common` pour multi-tenant)

Le secret copie a l'etape precedente est votre `AZURE_CLIENT_SECRET`.

## Etape 5 : Configurer l'application

Creez un fichier `.env` a la racine du projet (dossier `15/`) avec le contenu suivant :

```env
AZURE_CLIENT_ID=<votre-application-client-id>
AZURE_CLIENT_SECRET=<votre-client-secret>
AZURE_TENANT_ID=common
REDIRECT_URI=http://localhost:3001/auth/callback
FRONTEND_URL=http://localhost:3000
PORT=3001
SESSION_SECRET=<une-chaine-aleatoire-pour-la-securite>
```

Remplacez les valeurs entre `<>` par vos propres valeurs.

## Verification

1. Demarrez l'application backend et frontend

2. Ouvrez http://localhost:3000

3. Cliquez sur "Se connecter avec Microsoft"

4. Connectez-vous avec votre compte Microsoft

5. Acceptez les permissions demandees

6. Vous devriez etre redirige vers l'application avec acces aux fonctionnalites

## Depannage

### Erreur "AADSTS50011: The reply URL specified in the request does not match..."

Verifiez que l'URL de redirection dans Azure AD correspond exactement a celle configuree dans `.env` :
- Azure AD : `http://localhost:3001/auth/callback`
- `.env` : `REDIRECT_URI=http://localhost:3001/auth/callback`

### Erreur "AADSTS65001: The user or administrator has not consented..."

Certaines permissions necessitent le consentement d'un administrateur. Si vous utilisez un compte personnel, essayez de supprimer les permissions qui le necessitent (comme `ChannelMessage.Read.All`).

### Erreur "AADSTS700016: Application with identifier '...' was not found..."

Verifiez que le `AZURE_CLIENT_ID` dans `.env` correspond bien a l'Application ID dans Azure.

### Les fichiers OneDrive n'apparaissent pas

Assurez-vous que votre compte Microsoft a des fichiers dans OneDrive. Vous pouvez tester en allant sur https://onedrive.live.com.

### Les conversations Teams n'apparaissent pas

- Verifiez que vous avez des conversations dans Teams
- Si vous utilisez un compte personnel, les fonctionnalites Teams peuvent etre limitees
- La permission `ChannelMessage.Read.All` necessite un admin consent

## Ressources

- [Documentation Microsoft Graph](https://docs.microsoft.com/en-us/graph/overview)
- [MSAL Node.js](https://github.com/AzureAD/microsoft-authentication-library-for-js/tree/dev/lib/msal-node)
- [Microsoft Graph Explorer](https://developer.microsoft.com/en-us/graph/graph-explorer) - Pour tester les appels API

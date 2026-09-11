import { Configuration, LogLevel } from '@azure/msal-node';
import dotenv from 'dotenv';

dotenv.config({ path: '../.env' });

// Microsoft Graph API scopes required for the application
export const GRAPH_SCOPES = {
  mail: ['Mail.Read', 'Mail.Send'],
  onedrive: ['Files.Read', 'Files.ReadWrite'],
  teams: ['Chat.Read', 'ChannelMessage.Read.All'],
  user: ['User.Read']
};

// All scopes combined for initial authentication
export const ALL_SCOPES = [
  ...GRAPH_SCOPES.user,
  ...GRAPH_SCOPES.mail,
  ...GRAPH_SCOPES.onedrive,
  ...GRAPH_SCOPES.teams
];

// MSAL Configuration
export const msalConfig: Configuration = {
  auth: {
    clientId: process.env.AZURE_CLIENT_ID || '',
    authority: `https://login.microsoftonline.com/${process.env.AZURE_TENANT_ID || 'common'}`,
    clientSecret: process.env.AZURE_CLIENT_SECRET || ''
  },
  system: {
    loggerOptions: {
      loggerCallback: (level, message, containsPii) => {
        if (containsPii) return;
        switch (level) {
          case LogLevel.Error:
            console.error(message);
            break;
          case LogLevel.Warning:
            console.warn(message);
            break;
          case LogLevel.Info:
            console.info(message);
            break;
          case LogLevel.Verbose:
            console.debug(message);
            break;
        }
      },
      piiLoggingEnabled: false,
      logLevel: LogLevel.Warning
    }
  }
};

// Redirect URI for OAuth callback
export const REDIRECT_URI = process.env.REDIRECT_URI || 'http://localhost:3001/auth/callback';

// Frontend URL for redirects after authentication
export const FRONTEND_URL = process.env.FRONTEND_URL || 'http://localhost:3000';

// Microsoft Graph API base URL
export const GRAPH_API_ENDPOINT = 'https://graph.microsoft.com/v1.0';

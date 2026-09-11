import { Router, Request, Response } from 'express';
import { ConfidentialClientApplication } from '@azure/msal-node';
import { msalConfig, ALL_SCOPES, REDIRECT_URI, FRONTEND_URL } from '../config/auth';
import { GraphService } from '../services/graph';

const router = Router();

// Initialize MSAL client
const msalClient = new ConfidentialClientApplication(msalConfig);

/**
 * GET /auth/login
 * Redirects user to Microsoft login page
 */
router.get('/login', async (req: Request, res: Response) => {
  try {
    const authUrl = await msalClient.getAuthCodeUrl({
      scopes: ALL_SCOPES,
      redirectUri: REDIRECT_URI,
      responseMode: 'query'
    });

    res.redirect(authUrl);
  } catch (error) {
    console.error('Login error:', error);
    res.status(500).json({
      error: 'Login failed',
      message: 'Could not generate authentication URL'
    });
  }
});

/**
 * GET /auth/callback
 * OAuth callback - exchanges code for tokens
 */
router.get('/callback', async (req: Request, res: Response) => {
  const { code, error, error_description } = req.query;

  if (error) {
    console.error('OAuth error:', error, error_description);
    res.redirect(`${FRONTEND_URL}?error=${encodeURIComponent(error as string)}`);
    return;
  }

  if (!code) {
    res.redirect(`${FRONTEND_URL}?error=no_code`);
    return;
  }

  try {
    const tokenResponse = await msalClient.acquireTokenByCode({
      code: code as string,
      scopes: ALL_SCOPES,
      redirectUri: REDIRECT_URI
    });

    if (!tokenResponse) {
      throw new Error('No token response received');
    }

    // Store tokens in session
    req.session.accessToken = tokenResponse.accessToken;
    req.session.tokenExpiry = tokenResponse.expiresOn?.getTime();

    // Get user info
    const graphService = new GraphService(tokenResponse.accessToken);
    const user = await graphService.getMe();

    req.session.user = {
      id: user.id,
      displayName: user.displayName,
      mail: user.mail || user.userPrincipalName
    };

    // Redirect to frontend
    res.redirect(`${FRONTEND_URL}?login=success`);
  } catch (error) {
    console.error('Callback error:', error);
    res.redirect(`${FRONTEND_URL}?error=token_exchange_failed`);
  }
});

/**
 * GET /auth/logout
 * Clears session and redirects to Microsoft logout
 */
router.get('/logout', (req: Request, res: Response) => {
  req.session.destroy((err) => {
    if (err) {
      console.error('Session destroy error:', err);
    }

    // Redirect to Microsoft logout
    const logoutUrl = `https://login.microsoftonline.com/common/oauth2/v2.0/logout?post_logout_redirect_uri=${encodeURIComponent(FRONTEND_URL)}`;
    res.redirect(logoutUrl);
  });
});

/**
 * GET /auth/status
 * Returns current authentication status
 */
router.get('/status', (req: Request, res: Response) => {
  if (req.session?.accessToken && req.session?.user) {
    res.json({
      authenticated: true,
      user: req.session.user
    });
  } else {
    res.json({
      authenticated: false,
      user: null
    });
  }
});

/**
 * GET /auth/user
 * Returns current user info (requires auth)
 */
router.get('/user', (req: Request, res: Response) => {
  if (!req.session?.accessToken) {
    res.status(401).json({
      error: 'Unauthorized',
      message: 'Not logged in'
    });
    return;
  }

  res.json(req.session.user);
});

export default router;

import { Request, Response, NextFunction } from 'express';

// Extend Express Request type to include session data
declare module 'express-session' {
  interface SessionData {
    accessToken?: string;
    refreshToken?: string;
    tokenExpiry?: number;
    user?: {
      id: string;
      displayName: string;
      mail: string;
    };
  }
}

/**
 * Middleware to check if user is authenticated
 * Validates that an access token exists in the session
 */
export function requireAuth(req: Request, res: Response, next: NextFunction): void {
  if (!req.session?.accessToken) {
    res.status(401).json({
      error: 'Unauthorized',
      message: 'No access token found. Please login first.',
      loginUrl: '/auth/login'
    });
    return;
  }

  // Check if token is expired
  if (req.session.tokenExpiry && Date.now() > req.session.tokenExpiry) {
    res.status(401).json({
      error: 'Token expired',
      message: 'Your session has expired. Please login again.',
      loginUrl: '/auth/login'
    });
    return;
  }

  next();
}

/**
 * Helper to get access token from request
 */
export function getAccessToken(req: Request): string {
  if (!req.session?.accessToken) {
    throw new Error('No access token in session');
  }
  return req.session.accessToken;
}

/**
 * Optional auth middleware - doesn't reject if not authenticated
 * Just attaches user info if available
 */
export function optionalAuth(req: Request, res: Response, next: NextFunction): void {
  // Just continue - session data will be available if authenticated
  next();
}

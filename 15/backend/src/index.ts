import express, { Request, Response, NextFunction } from 'express';
import cors from 'cors';
import session from 'express-session';
import dotenv from 'dotenv';
import path from 'path';

// Load environment variables from root .env
dotenv.config({ path: path.join(__dirname, '../../.env') });

// Import routes
import authRoutes from './routes/auth';
import mailRoutes from './routes/mail';
import onedriveRoutes from './routes/onedrive';
import teamsRoutes from './routes/teams';

const app = express();
const PORT = process.env.PORT || 3001;

// CORS configuration for frontend
app.use(cors({
  origin: process.env.FRONTEND_URL || 'http://localhost:3000',
  credentials: true
}));

// Parse JSON bodies
app.use(express.json({ limit: '10mb' }));

// Session configuration
app.use(session({
  secret: process.env.SESSION_SECRET || 'hedwige-secret-key-change-in-production',
  resave: false,
  saveUninitialized: false,
  cookie: {
    secure: process.env.NODE_ENV === 'production',
    httpOnly: true,
    maxAge: 24 * 60 * 60 * 1000 // 24 hours
  }
}));

// Health check endpoint
app.get('/health', (req: Request, res: Response) => {
  res.json({
    status: 'ok',
    timestamp: new Date().toISOString(),
    version: '1.0.0'
  });
});

// API Routes
app.use('/auth', authRoutes);
app.use('/mail', mailRoutes);
app.use('/onedrive', onedriveRoutes);
app.use('/teams', teamsRoutes);

// 404 handler
app.use((req: Request, res: Response) => {
  res.status(404).json({
    error: 'Not Found',
    message: `Route ${req.method} ${req.path} not found`
  });
});

// Error handler
app.use((err: Error, req: Request, res: Response, next: NextFunction) => {
  console.error('Unhandled error:', err);
  res.status(500).json({
    error: 'Internal Server Error',
    message: process.env.NODE_ENV === 'development' ? err.message : 'An unexpected error occurred'
  });
});

// Start server
app.listen(PORT, () => {
  console.log(`🦉 Hedwige Backend running on http://localhost:${PORT}`);
  console.log(`📧 Mail API: http://localhost:${PORT}/mail`);
  console.log(`📁 OneDrive API: http://localhost:${PORT}/onedrive`);
  console.log(`💬 Teams API: http://localhost:${PORT}/teams`);
  console.log(`🔐 Auth: http://localhost:${PORT}/auth/login`);
});

export default app;

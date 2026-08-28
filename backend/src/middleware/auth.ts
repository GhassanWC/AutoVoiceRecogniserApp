import { NextFunction, Request, Response } from 'express';
import { verifyToken } from '../modules/auth/tokens';

declare module 'express-serve-static-core' {
  interface Request {
    userId?: string;
    isGuest?: boolean;
  }
}

export function requireAuth(req: Request, res: Response, next: NextFunction): void {
  const header = req.headers.authorization ?? '';
  const token = header.startsWith('Bearer ') ? header.slice('Bearer '.length) : null;
  const claims = token ? verifyToken(token) : null;
  if (!claims) {
    res.status(401).json({ error: 'Authentication required' });
    return;
  }
  req.userId = claims.sub;
  req.isGuest = claims.guest;
  next();
}

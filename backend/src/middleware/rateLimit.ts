import { NextFunction, Request, Response } from 'express';

interface Window {
  count: number;
  resetAt: number;
}

/**
 * Small fixed-window limiter, keyed by user id when authenticated, else IP.
 * For multi-instance deployments move this to Redis; the interface stays.
 */
export function rateLimit(maxRequests: number, windowMs: number) {
  const windows = new Map<string, Window>();

  // Prevent unbounded growth.
  setInterval(() => {
    const now = Date.now();
    for (const [key, window] of windows) {
      if (window.resetAt <= now) windows.delete(key);
    }
  }, windowMs).unref();

  return (req: Request, res: Response, next: NextFunction): void => {
    const key = req.userId ?? req.ip ?? 'unknown';
    const now = Date.now();
    let window = windows.get(key);
    if (!window || window.resetAt <= now) {
      window = { count: 0, resetAt: now + windowMs };
      windows.set(key, window);
    }
    window.count += 1;
    if (window.count > maxRequests) {
      res.status(429).json({ error: 'Too many requests, please slow down' });
      return;
    }
    next();
  };
}

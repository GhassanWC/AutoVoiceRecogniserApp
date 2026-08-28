import { NextFunction, Request, Response } from 'express';
import { HttpError } from '../modules/auth/auth.service';
import { log } from '../utils/logger';

/** Last-resort handler: friendly message out, full detail into the log only. */
export function errorHandler(
  error: unknown,
  _req: Request,
  res: Response,
  _next: NextFunction,
): void {
  if (error instanceof HttpError) {
    res.status(error.status).json({ error: error.message });
    return;
  }
  log.error('unhandled error', {
    message: error instanceof Error ? error.message : String(error),
    stack: error instanceof Error ? error.stack : undefined,
  });
  res.status(500).json({ error: 'Something went wrong. Please try again.' });
}

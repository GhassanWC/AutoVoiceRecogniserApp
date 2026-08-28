import jwt from 'jsonwebtoken';
import { env } from '../../config/env';

export interface TokenClaims {
  sub: string;
  guest: boolean;
}

const TOKEN_TTL = '30d';

export function signToken(claims: TokenClaims): string {
  return jwt.sign({ sub: claims.sub, guest: claims.guest }, env.JWT_SECRET, {
    expiresIn: TOKEN_TTL,
  });
}

export function verifyToken(token: string): TokenClaims | null {
  try {
    const payload = jwt.verify(token, env.JWT_SECRET);
    if (typeof payload === 'string' || !payload.sub) return null;
    return { sub: payload.sub, guest: Boolean((payload as Record<string, unknown>).guest) };
  } catch {
    return null;
  }
}

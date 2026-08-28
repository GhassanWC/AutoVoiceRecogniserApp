import { describe, expect, it } from 'vitest';
import { hashPassword, verifyPassword } from '../src/modules/auth/passwords';
import { signToken, verifyToken } from '../src/modules/auth/tokens';

describe('passwords', () => {
  it('verifies a correct password and rejects a wrong one', async () => {
    const hash = await hashPassword('correct horse battery staple');
    expect(await verifyPassword('correct horse battery staple', hash)).toBe(true);
    expect(await verifyPassword('wrong password', hash)).toBe(false);
  });

  it('rejects malformed stored hashes without throwing', async () => {
    expect(await verifyPassword('anything', 'garbage')).toBe(false);
  });
});

describe('tokens', () => {
  it('round-trips claims', () => {
    const token = signToken({ sub: 'user_123', guest: true });
    const claims = verifyToken(token);
    expect(claims).toEqual({ sub: 'user_123', guest: true });
  });

  it('rejects tampered tokens', () => {
    const token = signToken({ sub: 'user_123', guest: false });
    expect(verifyToken(token.slice(0, -2) + 'xx')).toBeNull();
  });
});

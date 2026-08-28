import { getStore, UserRecord } from '../../storage';
import { newId } from '../../utils/ids';
import { hashPassword, verifyPassword } from './passwords';
import { signToken } from './tokens';

export interface AuthResult {
  token: string;
  user: PublicUser;
}

export interface PublicUser {
  id: string;
  email: string | null;
  name: string | null;
  isGuest: boolean;
  preferredLanguage: string;
  showOriginalText: boolean;
  autoSpeak: boolean;
  saveHistory: boolean;
}

export function toPublicUser(user: UserRecord): PublicUser {
  return {
    id: user.id,
    email: user.email,
    name: user.name,
    isGuest: user.isGuest,
    preferredLanguage: user.preferredLanguage,
    showOriginalText: user.showOriginalText,
    autoSpeak: user.autoSpeak,
    saveHistory: user.saveHistory,
  };
}

function newUser(overrides: Partial<UserRecord>): UserRecord {
  return {
    id: newId('user'),
    email: null,
    name: null,
    passwordHash: null,
    isGuest: false,
    preferredLanguage: 'en',
    showOriginalText: true,
    autoSpeak: false,
    saveHistory: false,
    createdAt: new Date().toISOString(),
    ...overrides,
  };
}

/** "Try without account" — instant guest identity with default preferences. */
export async function createGuest(preferredLanguage?: string): Promise<AuthResult> {
  const user = await getStore().createUser(
    newUser({ isGuest: true, preferredLanguage: preferredLanguage ?? 'en' }),
  );
  return { token: signToken({ sub: user.id, guest: true }), user: toPublicUser(user) };
}

export async function register(email: string, password: string, name?: string): Promise<AuthResult> {
  const existing = await getStore().getUserByEmail(email);
  if (existing) throw new HttpError(409, 'An account with this email already exists');
  const user = await getStore().createUser(
    newUser({ email, name: name ?? null, passwordHash: await hashPassword(password) }),
  );
  return { token: signToken({ sub: user.id, guest: false }), user: toPublicUser(user) };
}

export async function login(email: string, password: string): Promise<AuthResult> {
  const user = await getStore().getUserByEmail(email);
  if (!user || !user.passwordHash || !(await verifyPassword(password, user.passwordHash))) {
    throw new HttpError(401, 'Invalid email or password');
  }
  return { token: signToken({ sub: user.id, guest: false }), user: toPublicUser(user) };
}

export class HttpError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

export interface UserRecord {
  id: string;
  /** null for guest users. */
  email: string | null;
  name: string | null;
  passwordHash: string | null;
  isGuest: boolean;
  preferredLanguage: string;
  showOriginalText: boolean;
  autoSpeak: boolean;
  saveHistory: boolean;
  createdAt: string;
}

export interface SessionRecord {
  id: string;
  userId: string;
  targetLanguage: string;
  startedAt: string;
  endedAt: string | null;
  translationCount: number;
}

export interface MessageRecord {
  id: string;
  sessionId: string;
  speakerId: string | null;
  speakerLabel: string | null;
  sourceLanguage: string;
  languageConfidence: number;
  originalText: string;
  translatedText: string;
  createdAt: string;
}

export interface UsageRecord {
  userId: string;
  /** Calendar month, "YYYY-MM". */
  month: string;
  speechSeconds: number;
  translatedCharacters: number;
}

export interface UserPreferencesPatch {
  preferredLanguage?: string;
  showOriginalText?: boolean;
  autoSpeak?: boolean;
  saveHistory?: boolean;
  name?: string;
}

/**
 * Persistence boundary. Two implementations: in-memory (default, no setup)
 * and PostgreSQL (set DATABASE_URL and run `npm run migrate`).
 *
 * Note what is deliberately NOT here: raw audio. Audio segments only ever
 * live in memory while being processed and are discarded immediately after.
 */
export interface Store {
  createUser(user: UserRecord): Promise<UserRecord>;
  getUserById(id: string): Promise<UserRecord | null>;
  getUserByEmail(email: string): Promise<UserRecord | null>;
  updateUserPreferences(id: string, patch: UserPreferencesPatch): Promise<UserRecord | null>;

  createSession(session: SessionRecord): Promise<SessionRecord>;
  getSession(id: string): Promise<SessionRecord | null>;
  endSession(id: string, endedAt: string, translationCount: number): Promise<void>;
  getSessionsForUser(userId: string): Promise<SessionRecord[]>;
  deleteSession(id: string, userId: string): Promise<boolean>;
  deleteAllSessionsForUser(userId: string): Promise<number>;

  addMessage(message: MessageRecord): Promise<void>;
  getMessagesForSession(sessionId: string): Promise<MessageRecord[]>;

  addUsage(userId: string, month: string, speechSeconds: number, translatedCharacters: number): Promise<void>;
  getUsage(userId: string, month: string): Promise<UsageRecord>;
}

export function currentMonth(now: Date = new Date()): string {
  return `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, '0')}`;
}

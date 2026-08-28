import {
  MessageRecord,
  SessionRecord,
  Store,
  UsageRecord,
  UserPreferencesPatch,
  UserRecord,
} from './types';

export class MemoryStore implements Store {
  private users = new Map<string, UserRecord>();
  private usersByEmail = new Map<string, string>();
  private sessions = new Map<string, SessionRecord>();
  private messages = new Map<string, MessageRecord[]>();
  private usage = new Map<string, UsageRecord>();

  async createUser(user: UserRecord): Promise<UserRecord> {
    this.users.set(user.id, { ...user });
    if (user.email) this.usersByEmail.set(user.email.toLowerCase(), user.id);
    return user;
  }

  async getUserById(id: string): Promise<UserRecord | null> {
    const user = this.users.get(id);
    return user ? { ...user } : null;
  }

  async getUserByEmail(email: string): Promise<UserRecord | null> {
    const id = this.usersByEmail.get(email.toLowerCase());
    return id ? this.getUserById(id) : null;
  }

  async updateUserPreferences(id: string, patch: UserPreferencesPatch): Promise<UserRecord | null> {
    const user = this.users.get(id);
    if (!user) return null;
    Object.assign(user, patch);
    return { ...user };
  }

  async createSession(session: SessionRecord): Promise<SessionRecord> {
    this.sessions.set(session.id, { ...session });
    return session;
  }

  async getSession(id: string): Promise<SessionRecord | null> {
    const session = this.sessions.get(id);
    return session ? { ...session } : null;
  }

  async endSession(id: string, endedAt: string, translationCount: number): Promise<void> {
    const session = this.sessions.get(id);
    if (!session) return;
    session.endedAt = endedAt;
    session.translationCount = translationCount;
  }

  async getSessionsForUser(userId: string): Promise<SessionRecord[]> {
    return [...this.sessions.values()]
      .filter((s) => s.userId === userId)
      .sort((a, b) => b.startedAt.localeCompare(a.startedAt))
      .map((s) => ({ ...s }));
  }

  async deleteSession(id: string, userId: string): Promise<boolean> {
    const session = this.sessions.get(id);
    if (!session || session.userId !== userId) return false;
    this.sessions.delete(id);
    this.messages.delete(id);
    return true;
  }

  async deleteAllSessionsForUser(userId: string): Promise<number> {
    let deleted = 0;
    for (const [id, session] of this.sessions) {
      if (session.userId === userId) {
        this.sessions.delete(id);
        this.messages.delete(id);
        deleted += 1;
      }
    }
    return deleted;
  }

  async addMessage(message: MessageRecord): Promise<void> {
    const list = this.messages.get(message.sessionId) ?? [];
    list.push({ ...message });
    this.messages.set(message.sessionId, list);
  }

  async getMessagesForSession(sessionId: string): Promise<MessageRecord[]> {
    return (this.messages.get(sessionId) ?? []).map((m) => ({ ...m }));
  }

  async addUsage(
    userId: string,
    month: string,
    speechSeconds: number,
    translatedCharacters: number,
  ): Promise<void> {
    const key = `${userId}:${month}`;
    const record = this.usage.get(key) ?? {
      userId,
      month,
      speechSeconds: 0,
      translatedCharacters: 0,
    };
    record.speechSeconds += speechSeconds;
    record.translatedCharacters += translatedCharacters;
    this.usage.set(key, record);
  }

  async getUsage(userId: string, month: string): Promise<UsageRecord> {
    return (
      this.usage.get(`${userId}:${month}`) ?? {
        userId,
        month,
        speechSeconds: 0,
        translatedCharacters: 0,
      }
    );
  }
}

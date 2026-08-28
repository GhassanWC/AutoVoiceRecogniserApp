import { Pool } from 'pg';
import {
  MessageRecord,
  SessionRecord,
  Store,
  UsageRecord,
  UserPreferencesPatch,
  UserRecord,
} from './types';

function rowToUser(row: Record<string, unknown>): UserRecord {
  return {
    id: row.id as string,
    email: (row.email as string | null) ?? null,
    name: (row.name as string | null) ?? null,
    passwordHash: (row.password_hash as string | null) ?? null,
    isGuest: row.is_guest as boolean,
    preferredLanguage: row.preferred_language as string,
    showOriginalText: row.show_original_text as boolean,
    autoSpeak: row.auto_speak as boolean,
    saveHistory: row.save_history as boolean,
    createdAt: (row.created_at as Date).toISOString(),
  };
}

function rowToSession(row: Record<string, unknown>): SessionRecord {
  return {
    id: row.id as string,
    userId: row.user_id as string,
    targetLanguage: row.target_language as string,
    startedAt: (row.started_at as Date).toISOString(),
    endedAt: row.ended_at ? (row.ended_at as Date).toISOString() : null,
    translationCount: row.translation_count as number,
  };
}

function rowToMessage(row: Record<string, unknown>): MessageRecord {
  return {
    id: row.id as string,
    sessionId: row.session_id as string,
    speakerId: (row.speaker_id as string | null) ?? null,
    speakerLabel: (row.speaker_label as string | null) ?? null,
    sourceLanguage: row.source_language as string,
    languageConfidence: row.language_confidence as number,
    originalText: row.original_text as string,
    translatedText: row.translated_text as string,
    createdAt: (row.created_at as Date).toISOString(),
  };
}

export class PostgresStore implements Store {
  constructor(private readonly pool: Pool) {}

  async createUser(user: UserRecord): Promise<UserRecord> {
    await this.pool.query(
      `INSERT INTO users
         (id, email, name, password_hash, is_guest, preferred_language,
          show_original_text, auto_speak, save_history, created_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
      [
        user.id,
        user.email,
        user.name,
        user.passwordHash,
        user.isGuest,
        user.preferredLanguage,
        user.showOriginalText,
        user.autoSpeak,
        user.saveHistory,
        user.createdAt,
      ],
    );
    return user;
  }

  async getUserById(id: string): Promise<UserRecord | null> {
    const result = await this.pool.query('SELECT * FROM users WHERE id = $1', [id]);
    const row = result.rows[0];
    return row ? rowToUser(row) : null;
  }

  async getUserByEmail(email: string): Promise<UserRecord | null> {
    const result = await this.pool.query('SELECT * FROM users WHERE lower(email) = lower($1)', [email]);
    const row = result.rows[0];
    return row ? rowToUser(row) : null;
  }

  async updateUserPreferences(id: string, patch: UserPreferencesPatch): Promise<UserRecord | null> {
    const sets: string[] = [];
    const values: unknown[] = [];
    const push = (column: string, value: unknown) => {
      values.push(value);
      sets.push(`${column} = $${values.length}`);
    };
    if (patch.preferredLanguage !== undefined) push('preferred_language', patch.preferredLanguage);
    if (patch.showOriginalText !== undefined) push('show_original_text', patch.showOriginalText);
    if (patch.autoSpeak !== undefined) push('auto_speak', patch.autoSpeak);
    if (patch.saveHistory !== undefined) push('save_history', patch.saveHistory);
    if (patch.name !== undefined) push('name', patch.name);
    if (sets.length === 0) return this.getUserById(id);

    values.push(id);
    const result = await this.pool.query(
      `UPDATE users SET ${sets.join(', ')} WHERE id = $${values.length} RETURNING *`,
      values,
    );
    const row = result.rows[0];
    return row ? rowToUser(row) : null;
  }

  async createSession(session: SessionRecord): Promise<SessionRecord> {
    await this.pool.query(
      `INSERT INTO translation_sessions
         (id, user_id, target_language, started_at, ended_at, translation_count)
       VALUES ($1,$2,$3,$4,$5,$6)`,
      [
        session.id,
        session.userId,
        session.targetLanguage,
        session.startedAt,
        session.endedAt,
        session.translationCount,
      ],
    );
    return session;
  }

  async getSession(id: string): Promise<SessionRecord | null> {
    const result = await this.pool.query('SELECT * FROM translation_sessions WHERE id = $1', [id]);
    const row = result.rows[0];
    return row ? rowToSession(row) : null;
  }

  async endSession(id: string, endedAt: string, translationCount: number): Promise<void> {
    await this.pool.query(
      'UPDATE translation_sessions SET ended_at = $2, translation_count = $3 WHERE id = $1',
      [id, endedAt, translationCount],
    );
  }

  async getSessionsForUser(userId: string): Promise<SessionRecord[]> {
    const result = await this.pool.query(
      'SELECT * FROM translation_sessions WHERE user_id = $1 ORDER BY started_at DESC',
      [userId],
    );
    return result.rows.map(rowToSession);
  }

  async deleteSession(id: string, userId: string): Promise<boolean> {
    const result = await this.pool.query(
      'DELETE FROM translation_sessions WHERE id = $1 AND user_id = $2',
      [id, userId],
    );
    return (result.rowCount ?? 0) > 0;
  }

  async deleteAllSessionsForUser(userId: string): Promise<number> {
    const result = await this.pool.query('DELETE FROM translation_sessions WHERE user_id = $1', [
      userId,
    ]);
    return result.rowCount ?? 0;
  }

  async addMessage(message: MessageRecord): Promise<void> {
    await this.pool.query(
      `INSERT INTO translation_messages
         (id, session_id, speaker_id, speaker_label, source_language,
          language_confidence, original_text, translated_text, created_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
      [
        message.id,
        message.sessionId,
        message.speakerId,
        message.speakerLabel,
        message.sourceLanguage,
        message.languageConfidence,
        message.originalText,
        message.translatedText,
        message.createdAt,
      ],
    );
  }

  async getMessagesForSession(sessionId: string): Promise<MessageRecord[]> {
    const result = await this.pool.query(
      'SELECT * FROM translation_messages WHERE session_id = $1 ORDER BY created_at ASC',
      [sessionId],
    );
    return result.rows.map(rowToMessage);
  }

  async addUsage(
    userId: string,
    month: string,
    speechSeconds: number,
    translatedCharacters: number,
  ): Promise<void> {
    await this.pool.query(
      `INSERT INTO usage_months (user_id, month, speech_seconds, translated_characters)
       VALUES ($1,$2,$3,$4)
       ON CONFLICT (user_id, month) DO UPDATE SET
         speech_seconds = usage_months.speech_seconds + EXCLUDED.speech_seconds,
         translated_characters = usage_months.translated_characters + EXCLUDED.translated_characters`,
      [userId, month, speechSeconds, translatedCharacters],
    );
  }

  async getUsage(userId: string, month: string): Promise<UsageRecord> {
    const result = await this.pool.query(
      'SELECT * FROM usage_months WHERE user_id = $1 AND month = $2',
      [userId, month],
    );
    const row = result.rows[0];
    if (!row) return { userId, month, speechSeconds: 0, translatedCharacters: 0 };
    return {
      userId,
      month,
      speechSeconds: Number(row.speech_seconds),
      translatedCharacters: Number(row.translated_characters),
    };
  }
}

-- Live Translator schema. Applied by `npm run migrate` (idempotent).
-- Raw audio is intentionally never stored — see docs/PRIVACY.md.

CREATE TABLE IF NOT EXISTS users (
  id                  TEXT PRIMARY KEY,
  email               TEXT UNIQUE,
  name                TEXT,
  password_hash       TEXT,
  is_guest            BOOLEAN NOT NULL DEFAULT FALSE,
  preferred_language  TEXT NOT NULL DEFAULT 'en',
  show_original_text  BOOLEAN NOT NULL DEFAULT TRUE,
  auto_speak          BOOLEAN NOT NULL DEFAULT FALSE,
  save_history        BOOLEAN NOT NULL DEFAULT FALSE,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS translation_sessions (
  id                 TEXT PRIMARY KEY,
  user_id            TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  target_language    TEXT NOT NULL,
  started_at         TIMESTAMPTZ NOT NULL,
  ended_at           TIMESTAMPTZ,
  translation_count  INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_sessions_user ON translation_sessions(user_id, started_at DESC);

CREATE TABLE IF NOT EXISTS translation_messages (
  id                   TEXT PRIMARY KEY,
  session_id           TEXT NOT NULL REFERENCES translation_sessions(id) ON DELETE CASCADE,
  speaker_id           TEXT,
  speaker_label        TEXT,
  source_language      TEXT NOT NULL,
  language_confidence  REAL NOT NULL DEFAULT 0,
  original_text        TEXT NOT NULL,
  translated_text      TEXT NOT NULL,
  created_at           TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_messages_session ON translation_messages(session_id, created_at);

CREATE TABLE IF NOT EXISTS usage_months (
  user_id                TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  month                  TEXT NOT NULL,
  speech_seconds         DOUBLE PRECISION NOT NULL DEFAULT 0,
  translated_characters  BIGINT NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, month)
);

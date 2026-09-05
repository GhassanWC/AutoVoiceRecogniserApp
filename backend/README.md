# Live Translator — Backend

Node.js + TypeScript server providing the real-time translation pipeline over
WebSockets, with a REST API for auth, preferences and history.

## Run

```bash
npm install
npm run dev        # http://localhost:8080, mock providers, in-memory storage
```

Smoke-test the whole pipeline (server must be running):

```bash
npm run simulate   # streams 3 fake speech segments, prints Arabic translations
```

Other commands: `npm test` (vitest), `npm run typecheck`, `npm run build` +
`npm start` (production), `npm run migrate` (PostgreSQL schema),
`npm run verify:providers` (REAL speech + translation API smoke test — run it
whenever translations fail in the app; prints PASS or the concrete HTTP
status/error, never the key).

## Configuration

Copy `.env.example` → `.env`. Everything has a safe development default.

| Variable | Values | Notes |
|---|---|---|
| `PORT` | number | default 8080 |
| `JWT_SECRET` | string | **must** be changed in production (refuses to start otherwise) |
| `DATABASE_URL` | postgres URL | unset → in-memory storage |
| `SPEECH_PROVIDER` | `mock` `openai` `deepgram` | **production: `openai`** — OpenAI realtime transcription (gpt-4o-transcribe-diarize, far-field noise reduction, diarization, no source-language configuration or allowlist). `deepgram` is optional (nova-3 multi, ten-language limit); `mock` uses per-segment batch recognition |
| `SPEECH_API_KEY` | string | key for the chosen speech provider (OpenAI key for `openai`; may equal `TRANSLATION_API_KEY`) |
| `SPEECH_MODEL` | string | optional realtime model override; default `gpt-4o-transcribe-diarize` |
| `TRANSLATION_PROVIDER` | `mock` `openai` `google` | **production: `openai`** |
| `TRANSLATION_API_KEY` | string | OpenAI key for `openai` |
| `TRANSLATION_MODEL` | string | optional; default `gpt-4o-mini` |
| `DIARIZATION_PROVIDER` | `heuristic` `none` | batch-fallback path only; the streaming pipeline uses Deepgram's diarization |
| `MAX_SESSION_MINUTES` | number | hard cap per listening session (120) |
| `FREE_MONTHLY_MINUTES` | number | processed-speech quota per user; `0` = unlimited |
| `MAX_SEGMENT_SECONDS` | number | reject overlong segments (30) |

## PostgreSQL

```bash
# e.g. docker run -d -p 5432:5432 -e POSTGRES_PASSWORD=dev -e POSTGRES_DB=live_translator postgres:16
export DATABASE_URL=postgres://postgres:dev@localhost:5432/live_translator
npm run migrate
npm run dev
```

Schema: `src/storage/schema.sql` (users, translation_sessions,
translation_messages, usage_months — no audio anywhere).

## REST API

All bodies JSON; authenticated routes take `Authorization: Bearer <jwt>`.

```text
GET    /health
POST   /auth/guest                     {preferredLanguage?}        → {token, user}
POST   /auth/register                  {email, password, name?}    → {token, user}
POST   /auth/login                     {email, password}           → {token, user}
GET    /user/profile                                               → {user}
PATCH  /user/preferences               {preferredLanguage?, showOriginalText?,
                                        autoSpeak?, saveHistory?, name?}
GET    /translation/history                                        → {sessions}
GET    /translation/history/:sessionId                             → {session, messages}
DELETE /translation/session/:sessionId
DELETE /translation/history
```

## WebSocket: `/live-translation?token=<jwt>`

See [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md#websocket-protocol) for the
full protocol (JSON control messages + binary PCM frames with sequence
numbers, duplicate suppression and reconnect semantics).

## Deployment notes

- Terminate TLS in front (WSS/HTTPS only in production).
- Set `NODE_ENV=production`, a real `JWT_SECRET`, and `DATABASE_URL`.
- The rate limiter and usage metering are per-process; behind a load balancer
  move both to Redis (the middleware/service interfaces are the seams).
- Logs are single-line JSON on stdout — point your collector at them. They
  deliberately never contain conversation text.

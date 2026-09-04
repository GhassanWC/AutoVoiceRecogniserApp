import { IncomingMessage, Server } from 'http';
import { WebSocket, WebSocketServer } from 'ws';
import { createDiarizationProvider } from '../../providers/diarization';
import { SpeechRecognitionProvider, StreamingSpeechProvider } from '../../providers/speech';
import { TranslationProvider } from '../../providers/translation';
import { log } from '../../utils/logger';
import { verifyToken } from '../auth/tokens';
import { LiveSession } from './live_session';
import { clientMessageSchema, parseAudioFrame, ServerMessage } from './protocol';

const HEARTBEAT_INTERVAL_MS = 30_000;
/** Generous ceiling — normal streaming sends ~10 audio frames per second. */
const MAX_MESSAGES_PER_SECOND = 120;

function extractToken(request: IncomingMessage): string | null {
  const url = new URL(request.url ?? '/', 'http://localhost');
  const queryToken = url.searchParams.get('token');
  if (queryToken) return queryToken;
  const header = request.headers.authorization ?? '';
  return header.startsWith('Bearer ') ? header.slice('Bearer '.length) : null;
}

export function attachRealtimeServer(
  httpServer: Server,
  providers: {
    speech: SpeechRecognitionProvider;
    streamingSpeech?: StreamingSpeechProvider | null;
    translation: TranslationProvider;
  },
): WebSocketServer {
  const wss = new WebSocketServer({ server: httpServer, path: '/live-translation' });

  wss.on('connection', (socket: WebSocket, request: IncomingMessage) => {
    const token = extractToken(request);
    const claims = token ? verifyToken(token) : null;
    if (!claims) {
      socket.close(4401, 'Authentication required');
      return;
    }

    const send = (message: ServerMessage): void => {
      if (socket.readyState === WebSocket.OPEN) {
        socket.send(JSON.stringify(message));
      }
    };

    const session = new LiveSession({
      userId: claims.sub,
      speech: providers.speech,
      streamingSpeech: providers.streamingSpeech ?? null,
      translation: providers.translation,
      diarization: createDiarizationProvider(), // stateful → one per connection
      send,
    });

    log.info('ws connected', { userId: claims.sub });

    let alive = true;
    socket.on('pong', () => {
      alive = true;
    });
    const heartbeat = setInterval(() => {
      if (!alive) {
        socket.terminate();
        return;
      }
      alive = false;
      socket.ping();
    }, HEARTBEAT_INTERVAL_MS);

    let messageCount = 0;
    let windowStart = Date.now();

    socket.on('message', (data: Buffer, isBinary: boolean) => {
      const now = Date.now();
      if (now - windowStart >= 1000) {
        windowStart = now;
        messageCount = 0;
      }
      messageCount += 1;
      if (messageCount > MAX_MESSAGES_PER_SECOND) {
        log.warn('ws rate limit exceeded, closing', { userId: claims.sub });
        socket.close(4429, 'Rate limit exceeded');
        return;
      }

      if (isBinary) {
        const frame = parseAudioFrame(data);
        if (frame) session.handleAudioFrame(frame);
        return;
      }

      let parsed: unknown;
      try {
        parsed = JSON.parse(data.toString('utf8'));
      } catch {
        send({ type: 'error', code: 'bad_json', message: 'Invalid JSON message.', recoverable: true });
        return;
      }
      const result = clientMessageSchema.safeParse(parsed);
      if (!result.success) {
        send({ type: 'error', code: 'bad_message', message: 'Unrecognized message.', recoverable: true });
        return;
      }

      const message = result.data;
      switch (message.type) {
        case 'session_start':
          void session.handleSessionStart(message);
          break;
        case 'segment_start':
          session.handleSegmentStart(message);
          break;
        case 'segment_end':
          session.handleSegmentEnd(message.segmentId, message.durationMs);
          break;
        case 'session_stop':
          void session.handleSessionStop();
          break;
        case 'ping':
          send({ type: 'pong', t: message.t });
          break;
      }
    });

    socket.on('close', () => {
      clearInterval(heartbeat);
      void session.dispose();
      log.info('ws disconnected', { userId: claims.sub });
    });

    socket.on('error', (error) => {
      log.warn('ws error', { userId: claims.sub, message: error.message });
    });
  });

  return wss;
}

import { IncomingMessage, Server } from 'http';
import { WebSocket, WebSocketServer } from 'ws';
import { createDiarizationProvider } from '../../providers/diarization';
import { SpeechRecognitionProvider, StreamingSpeechProvider } from '../../providers/speech';
import { RealtimeTranslationProvider, TranslationProvider } from '../../providers/translation';
import { LanguageDetector, MetadataTranscriber } from '../../utils/language_detect';
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
    realtimeTranslation?: RealtimeTranslationProvider | null;
    languageDetector?: LanguageDetector | null;
    metadataTranscriber?: MetadataTranscriber | null;
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
      realtimeTranslation: providers.realtimeTranslation ?? null,
      languageDetector: providers.languageDetector ?? null,
      metadataTranscriber: providers.metadataTranscriber ?? null,
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

    // Control messages MUST be handled strictly in order: session_start is
    // async (allowance check), and the client sends stream_start immediately
    // after it — often coalesced into the same TCP packet. Handling
    // stream_start synchronously while session_start is still awaiting made
    // the server reject it with no_session, silently discarding ALL of the
    // session's audio ("mic active, nothing ever appears"). Audio frames stay
    // outside the chain: they are order-tolerant and must not queue.
    let controlChain: Promise<void> = Promise.resolve();
    const enqueueControl = (work: () => void | Promise<void>): void => {
      controlChain = controlChain.then(work).catch((error) => {
        log.error('control message handling failed', {
          userId: claims.sub,
          message: error instanceof Error ? error.message : String(error),
        });
      });
    };

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
          enqueueControl(() => session.handleSessionStart(message));
          break;
        case 'segment_start':
          enqueueControl(() => session.handleSegmentStart(message));
          break;
        case 'stream_start':
          enqueueControl(() => session.handleStreamStart(message));
          break;
        case 'segment_end':
          enqueueControl(() => session.handleSegmentEnd(message.segmentId, message.durationMs));
          break;
        case 'session_stop':
          enqueueControl(() => session.handleSessionStop());
          break;
        case 'retry_translation':
          enqueueControl(() => session.handleRetryTranslation(message.messageId));
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

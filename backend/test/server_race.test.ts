import { createServer, Server } from 'http';
import { AddressInfo } from 'net';
import { WebSocket } from 'ws';
import { afterEach, describe, expect, it } from 'vitest';
import { attachRealtimeServer } from '../src/modules/realtime/realtime.server';
import { signToken } from '../src/modules/auth/tokens';
import { MockSpeechProvider } from '../src/providers/speech/mock';
import { StreamingSpeechProvider, StreamingSpeechSession } from '../src/providers/speech/types';
import { MockTranslationProvider } from '../src/providers/translation/mock';
import { setStore } from '../src/storage';
import { MemoryStore } from '../src/storage/memory';

/**
 * Regression: the phone sends session_start and stream_start back-to-back
 * (often coalesced into one TCP packet). session_start's handler awaits an
 * allowance check before it sets the session id; handling stream_start
 * synchronously in the meantime rejected it with no_session — silently
 * discarding ALL of the session's audio ("mic active, nothing ever appears").
 * Control messages must be processed strictly in order.
 */

/** Store whose usage lookup is slow — guarantees the race without the fix. */
class SlowUsageStore extends MemoryStore {
  override async getUsage(userId: string, month: string): ReturnType<MemoryStore['getUsage']> {
    await new Promise((resolve) => setTimeout(resolve, 50));
    return super.getUsage(userId, month);
  }
}

describe('realtime server control-message ordering', () => {
  let httpServer: Server | null = null;

  afterEach(async () => {
    await new Promise<void>((resolve) => {
      if (!httpServer) return resolve();
      httpServer.close(() => resolve());
      httpServer = null as unknown as Server;
    });
  });

  it('accepts stream_start sent immediately after session_start (slow allowance check)', async () => {
    setStore(new SlowUsageStore());
    httpServer = createServer();
    const idleStreamingProvider: StreamingSpeechProvider = {
      name: 'idle-stream',
      createSession(): StreamingSpeechSession {
        return {
          sendAudio: () => undefined,
          finalize: () => undefined,
          close: async () => undefined,
          onUtterance: () => undefined,
          onFinalized: () => undefined,
          onError: () => undefined,
        };
      },
    };
    attachRealtimeServer(httpServer, {
      speech: new MockSpeechProvider(),
      streamingSpeech: idleStreamingProvider,
      translation: new MockTranslationProvider(),
    });
    await new Promise<void>((resolve) => httpServer!.listen(0, resolve));
    const port = (httpServer.address() as AddressInfo).port;

    const token = signToken({ sub: 'user_race_test', guest: true });
    const received: Array<{ type: string; [key: string]: unknown }> = [];
    const ws = new WebSocket(`ws://127.0.0.1:${port}/live-translation?token=${token}`);

    await new Promise<void>((resolve, reject) => {
      ws.on('error', reject);
      ws.on('open', () => {
        // Exactly like the phone: both control messages, no waiting between.
        ws.send(JSON.stringify({ type: 'session_start', targetLanguage: 'ar', saveHistory: false }));
        ws.send(
          JSON.stringify({
            type: 'stream_start',
            streamId: '123e4567-e89b-42d3-a456-426614174000',
            sampleRate: 16000,
            channels: 1,
            encoding: 'pcm16',
          }),
        );
      });
      ws.on('message', (data: Buffer) => {
        received.push(JSON.parse(data.toString('utf8')) as (typeof received)[number]);
        // status "hearing" is the server acknowledging the audio stream.
        if (received.some((m) => m.type === 'status')) resolve();
      });
      setTimeout(() => resolve(), 2000).unref?.();
    });
    ws.close();

    expect(received.find((m) => m.type === 'error')).toBeUndefined(); // no no_session
    expect(received.find((m) => m.type === 'session_started')).toBeDefined();
    expect(received.find((m) => m.type === 'status')).toMatchObject({ state: 'hearing' });
    // And strictly in that order: the session existed before the stream opened.
    const sessionIndex = received.findIndex((m) => m.type === 'session_started');
    const statusIndex = received.findIndex((m) => m.type === 'status');
    expect(sessionIndex).toBeGreaterThanOrEqual(0);
    expect(statusIndex).toBeGreaterThan(sessionIndex);
  });
});

/**
 * Smoke-test client: connects to a running backend (npm run dev in another
 * terminal), starts a guest session and streams three fake speech segments.
 * With the mock providers this prints a full multilingual → Arabic demo
 * conversation without touching the microphone or any paid API.
 *
 * Usage: npm run simulate [-- ws://host:port]
 */
import { randomUUID } from 'crypto';
import WebSocket from 'ws';
import { encodeAudioFrame } from '../src/modules/realtime/protocol';

const BASE = process.argv[2] ?? 'http://localhost:8080';
const WS_BASE = BASE.replace(/^http/, 'ws');
const SAMPLE_RATE = 16000;

function sineWavePcm(seconds: number, frequency = 220): Buffer {
  const samples = Math.floor(SAMPLE_RATE * seconds);
  const pcm = Buffer.alloc(samples * 2);
  for (let i = 0; i < samples; i++) {
    const value = Math.round(Math.sin((2 * Math.PI * frequency * i) / SAMPLE_RATE) * 8000);
    pcm.writeInt16LE(value, i * 2);
  }
  return pcm;
}

async function main(): Promise<void> {
  const auth = await fetch(`${BASE}/auth/guest`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ preferredLanguage: 'ar' }),
  });
  if (!auth.ok) throw new Error(`guest auth failed: ${auth.status}`);
  const { token } = (await auth.json()) as { token: string };
  console.log('guest token acquired');

  const socket = new WebSocket(`${WS_BASE}/live-translation?token=${encodeURIComponent(token)}`);

  socket.on('open', async () => {
    socket.send(JSON.stringify({ type: 'session_start', targetLanguage: 'ar' }));

    for (let i = 0; i < 3; i++) {
      await new Promise((resolve) => setTimeout(resolve, 700));
      const segmentId = randomUUID();
      socket.send(
        JSON.stringify({
          type: 'segment_start',
          segmentId,
          sampleRate: SAMPLE_RATE,
          channels: 1,
          encoding: 'pcm16',
        }),
      );
      // Stream ~1.5s of audio in 100ms chunks, like the app's VAD would.
      const chunk = sineWavePcm(0.1);
      for (let seq = 0; seq < 15; seq++) {
        socket.send(encodeAudioFrame(segmentId, seq, chunk));
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      socket.send(JSON.stringify({ type: 'segment_end', segmentId, durationMs: 1500 }));
    }

    await new Promise((resolve) => setTimeout(resolve, 2500));
    socket.send(JSON.stringify({ type: 'session_stop' }));
  });

  socket.on('message', (data) => {
    const message = JSON.parse(String(data));
    if (message.type === 'translation') {
      console.log(
        `[${message.speakerLabel ?? 'Speaker'} · ${message.sourceLanguage}] ` +
          `${message.originalText}  →  ${message.translatedText}`,
      );
    } else {
      console.log(`(${message.type})`, JSON.stringify(message));
    }
    if (message.type === 'session_ended') socket.close();
  });

  socket.on('close', () => {
    console.log('done');
    process.exit(0);
  });
  socket.on('error', (error) => {
    console.error('ws error:', error.message);
    process.exit(1);
  });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});

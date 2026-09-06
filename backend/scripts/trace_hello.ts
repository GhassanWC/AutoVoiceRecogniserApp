/**
 * End-to-end live trace: simulates the phone exactly (guest auth → WS →
 * session_start → stream_start → paced PCM of a spoken "Hello") and prints
 * every server→client message. Combined with the backend's [2]-[5] stage
 * logs, this pinpoints where the pipeline breaks. Run the backend first.
 */
import { readFileSync } from 'fs';
import { join } from 'path';
import { randomUUID } from 'crypto';
import { WebSocket } from 'ws';

const BASE = process.env.TRACE_BASE_URL ?? 'http://localhost:8080';

function readWav(path: string): { pcm: Buffer; rate: number } {
  const wav = readFileSync(path);
  let offset = 12;
  let rate = 24000;
  let pcm = Buffer.alloc(0);
  while (offset + 8 <= wav.length) {
    const id = wav.toString('ascii', offset, offset + 4);
    const size = wav.readUInt32LE(offset + 4);
    if (id === 'fmt ') rate = wav.readUInt32LE(offset + 12);
    if (id === 'data') pcm = wav.subarray(offset + 8, offset + 8 + size);
    offset += 8 + size + (size % 2);
  }
  return { pcm, rate };
}

function frame(streamId: string, sequence: number, pcm: Buffer): Buffer {
  const header = Buffer.alloc(41);
  header.writeUInt8(1, 0);
  header.write(streamId, 1, 36, 'ascii');
  header.writeUInt32LE(sequence, 37);
  return Buffer.concat([header, pcm]);
}

async function main(): Promise<void> {
  const auth = await fetch(`${BASE}/auth/guest`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ preferredLanguage: 'ar' }),
  });
  const { token } = (await auth.json()) as { token: string };
  console.log('[trace] guest token acquired');

  const { pcm, rate } = readWav(join(__dirname, '..', 'fixtures', 'english_hello.wav'));
  const streamId = randomUUID();
  const ws = new WebSocket(`${BASE.replace('http', 'ws')}/live-translation?token=${token}`);

  ws.on('open', () => {
    console.log('[trace] WS connected');
    ws.send(JSON.stringify({ type: 'session_start', targetLanguage: 'ar', saveHistory: false }));
    ws.send(
      JSON.stringify({
        type: 'stream_start',
        streamId,
        sampleRate: rate,
        channels: 1,
        encoding: 'pcm16',
      }),
    );
    // Pace ~real-time like the phone: 100 ms chunks + 6 s of trailing room
    // tone (enough for the failover deadline + fallback replay if needed).
    const chunkBytes = (rate * 2) / 10;
    const chunks: Buffer[] = [];
    for (let i = 0; i < pcm.length; i += chunkBytes) {
      chunks.push(pcm.subarray(i, Math.min(pcm.length, i + chunkBytes)));
    }
    for (let i = 0; i < 60; i++) chunks.push(Buffer.alloc(chunkBytes));
    let seq = 0;
    const pump = setInterval(() => {
      if (seq >= chunks.length) {
        clearInterval(pump);
        return;
      }
      if (seq === 0) console.log('[1] MOBILE_AUDIO_SENT (first chunk)');
      ws.send(frame(streamId, seq, chunks[seq]!));
      seq += 1;
    }, 100);
  });

  ws.on('message', (data: Buffer) => {
    const text = data.toString('utf8');
    let type = '?';
    try {
      type = (JSON.parse(text) as { type?: string }).type ?? '?';
    } catch {
      /* binary — not expected */
    }
    if (type === 'translation_started') console.log(`[6≙] CLIENT_RECEIVED ${text}`);
    else if (type === 'translation_delta') console.log(`[7≙] CLIENT_RECEIVED ${text}`);
    else console.log(`[trace] CLIENT_RECEIVED ${text}`);
  });
  ws.on('close', (code) => {
    console.log('[trace] WS closed', code);
    process.exit(0);
  });
  ws.on('error', (error) => {
    console.log('[trace] WS error', (error as Error).message);
    process.exit(1);
  });

  setTimeout(() => {
    console.log('[trace] done — closing');
    ws.send(JSON.stringify({ type: 'session_stop' }));
    setTimeout(() => ws.close(), 2000);
  }, 25_000);
}

void main().catch((error) => {
  console.error('[trace] crashed:', error instanceof Error ? error.message : error);
  process.exit(1);
});

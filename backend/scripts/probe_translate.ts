/* Probe the gpt-realtime-translate endpoint: dump every raw server event
 * (audio payloads truncated) so we can see the real protocol. */
import { readFileSync } from 'fs';
import { join } from 'path';
import { WebSocket } from 'ws';

const key = process.env.TRANSLATION_API_KEY ?? '';
const fixture = join(process.env.FIXTURES ?? '', 'english_hello.wav');

function readWavPcm(path: string): { pcm: Buffer; rate: number } {
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

function resample(pcm: Buffer, from: number, to: number): Buffer {
  if (from === to) return pcm;
  const inN = Math.floor(pcm.length / 2);
  const outN = Math.round((inN * to) / from);
  const out = Buffer.alloc(outN * 2);
  const step = (inN - 1) / Math.max(1, outN - 1);
  for (let i = 0; i < outN; i++) {
    const pos = i * step;
    const idx = Math.floor(pos);
    const frac = pos - idx;
    const a = pcm.readInt16LE(idx * 2);
    const b = idx + 1 < inN ? pcm.readInt16LE((idx + 1) * 2) : a;
    out.writeInt16LE(Math.round(a + (b - a) * frac), i * 2);
  }
  return out;
}

const url = 'wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate';
const ws = new WebSocket(url, { headers: { Authorization: `Bearer ${key}` } });

ws.on('open', () => {
  console.log('== OPEN ==');
  ws.send(
    JSON.stringify({
      type: 'session.update',
      session: { audio: { output: { language: 'ar' } } },
    }),
  );
  const { pcm, rate } = readWavPcm(fixture);
  const audio = resample(pcm, rate, 24000);
  const chunk = 4800; // 100ms @24k
  let sent = 0;
  for (let i = 0; i < audio.length; i += chunk) {
    ws.send(
      JSON.stringify({
        type: 'session.input_audio_buffer.append',
        audio: audio.subarray(i, i + chunk).toString('base64'),
      }),
    );
    sent += 1;
  }
  const silence = Buffer.alloc(chunk).toString('base64');
  for (let i = 0; i < 25; i++) {
    ws.send(JSON.stringify({ type: 'session.input_audio_buffer.append', audio: silence }));
  }
  console.log(`== sent ${sent} audio chunks + 2.5s silence ==`);
  setTimeout(() => {
    console.log('== closing ==');
    try { ws.send(JSON.stringify({ type: 'session.close' })); } catch {}
    setTimeout(() => ws.close(), 3000);
  }, 20000);
});

ws.on('message', (data: Buffer) => {
  let parsed: Record<string, unknown>;
  try { parsed = JSON.parse(data.toString('utf8')); } catch { console.log('RAW', data.length, 'bytes'); return; }
  for (const k of Object.keys(parsed)) {
    const v = parsed[k];
    if (typeof v === 'string' && v.length > 120) parsed[k] = `${v.slice(0, 60)}…(${v.length} chars)`;
  }
  console.log('EVENT', JSON.stringify(parsed));
});
ws.on('close', (code) => { console.log('== CLOSED', code, '=='); process.exit(0); });
ws.on('error', (err) => { console.log('== SOCKET ERROR ==', err.message); process.exit(1); });

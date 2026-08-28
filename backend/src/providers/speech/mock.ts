import { SpeechRecognitionProvider, TranscriptionRequest, TranscriptionResult } from './types';

/**
 * Development provider: returns a rotating multilingual conversation without
 * calling any paid API, so the full pipeline (and the mobile UI) can be
 * exercised with any audio input.
 */
const SCRIPT: Array<Omit<TranscriptionResult, 'transcriptionConfidence'>> = [
  { text: 'Hola hermano, ¿cómo estás?', language: 'es', languageConfidence: 0.97 },
  { text: 'My mother is sick.', language: 'en', languageConfidence: 0.95 },
  { text: "Où est l'hôtel?", language: 'fr', languageConfidence: 0.96 },
  { text: '¿Quieres venir con nosotros?', language: 'es', languageConfidence: 0.94 },
  { text: 'The restaurant closes at nine.', language: 'en', languageConfidence: 0.93 },
  { text: 'Wir müssen jetzt gehen.', language: 'de', languageConfidence: 0.92 },
  { text: '这里的食物很好吃。', language: 'zh', languageConfidence: 0.9 },
  { text: 'ร้านอาหารอยู่ที่ไหน', language: 'th', languageConfidence: 0.88 },
];

export class MockSpeechProvider implements SpeechRecognitionProvider {
  readonly name = 'mock';
  private index = 0;

  async transcribe(request: TranscriptionRequest): Promise<TranscriptionResult> {
    // Simulate provider latency.
    await new Promise((resolve) => setTimeout(resolve, 250));
    // Very short blips behave like real providers: nothing recognized.
    if (request.durationMs < 300) {
      return { text: '', language: 'und', languageConfidence: 0, transcriptionConfidence: 0 };
    }
    const line = SCRIPT[this.index % SCRIPT.length]!;
    this.index += 1;
    return { ...line, transcriptionConfidence: 0.9 };
  }
}

import { TranslationProvider, TranslationRequest, TranslationResult } from './types';

/**
 * Development provider. Knows the phrases produced by MockSpeechProvider so
 * the end-to-end demo reads like the real product when the target is Arabic;
 * anything else gets a visible pseudo-translation marker.
 */
const CANNED_AR: Record<string, string> = {
  'Hola hermano, ¿cómo estás?': 'مرحباً يا أخي، كيف حالك؟',
  'My mother is sick.': 'أمي مريضة.',
  "Où est l'hôtel?": 'أين الفندق؟',
  '¿Quieres venir con nosotros?': 'هل تريد الذهاب معنا؟',
  'The restaurant closes at nine.': 'المطعم يغلق الساعة التاسعة.',
  'Wir müssen jetzt gehen.': 'يجب أن نذهب الآن.',
  '这里的食物很好吃。': 'الطعام هنا لذيذ جداً.',
  'ร้านอาหารอยู่ที่ไหน': 'أين المطعم؟',
};

const CANNED_EN: Record<string, string> = {
  'Hola hermano, ¿cómo estás?': 'Hello brother, how are you?',
  'My mother is sick.': 'My mother is sick.',
  "Où est l'hôtel?": 'Where is the hotel?',
  '¿Quieres venir con nosotros?': 'Do you want to come with us?',
  'The restaurant closes at nine.': 'The restaurant closes at nine.',
  'Wir müssen jetzt gehen.': 'We have to go now.',
  '这里的食物很好吃。': 'The food here is delicious.',
  'ร้านอาหารอยู่ที่ไหน': 'Where is the restaurant?',
};

export class MockTranslationProvider implements TranslationProvider {
  readonly name = 'mock';

  async translate(request: TranslationRequest): Promise<TranslationResult> {
    await new Promise((resolve) => setTimeout(resolve, 150));
    const canned =
      request.targetLanguage === 'ar'
        ? CANNED_AR[request.text]
        : request.targetLanguage === 'en'
          ? CANNED_EN[request.text]
          : undefined;
    return {
      translatedText: canned ?? `[${request.targetLanguage}] ${request.text}`,
    };
  }
}

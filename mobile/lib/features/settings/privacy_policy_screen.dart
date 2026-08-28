import 'package:flutter/material.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  static const _sections = <(String, String)>[
    (
      'When the microphone is used',
      'The microphone is only active while a Live Translation session is running — '
          'after you press “Start Listening” and before you press “Stop Listening”. '
          'The app never records secretly, never starts by itself, and always shows a '
          'visible “Listening” indicator (plus a system notification on Android) while active.'
    ),
    (
      'What audio is processed',
      'Speech detection runs on your phone. Only short segments that actually contain '
          'speech are sent, encrypted, to our translation service. Silence and background '
          'noise are not uploaded.'
    ),
    (
      'Is audio stored?',
      'No. Audio segments are processed in memory to produce the transcription and '
          'translation, then discarded immediately. Raw audio is never written to disk '
          'on the server or on your phone.'
    ),
    (
      'What text is stored',
      'By default, nothing. If you enable “Save translation history”, translated '
          'conversations (text only) are stored on your device, and you can delete them '
          'at any time from History or Settings.'
    ),
    (
      'Who processes the data',
      'Speech recognition and translation may be performed by third-party AI providers '
          '(for example speech-to-text and translation APIs) acting as processors. '
          'Segments are sent to them over encrypted connections solely to produce your '
          'translation.'
    ),
    (
      'Deleting your data',
      'Use “Delete history” in Settings to remove all locally saved conversations. '
          'Server-side session records contain metadata only (no audio) and are used for '
          'service operation and abuse prevention.'
    ),
    (
      'Local laws',
      'Laws about recording or transcribing conversations around you vary by country '
          'and region. You are responsible for using Live Translator in a lawful and '
          'respectful way — when in doubt, tell people nearby that translation is running.'
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy Policy')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Privacy is a core feature of Live Translator, not an afterthought.',
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          for (final (title, body) in _sections) ...[
            Text(title, style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w800,
            )),
            const SizedBox(height: 6),
            Text(body, style: theme.textTheme.bodyMedium?.copyWith(height: 1.5)),
            const SizedBox(height: 18),
          ],
        ],
      ),
    );
  }
}

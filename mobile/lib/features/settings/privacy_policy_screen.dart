import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../widgets/components/app_background.dart';
import '../../widgets/components/glass_card.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  static const _sections = <(String, String)>[
    (
      'When the microphone is used',
      'The microphone is only active while a Live Translation session is running — '
          'after you press “Start Listening” and before you press “Stop Listening”. '
          'The app never records secretly, never starts by itself, and always shows a '
          'visible “Listening” indicator (plus a system notification on Android) while active. '
          'Leaving the app also stops listening.'
    ),
    (
      'What audio is processed',
      'While you are listening, microphone audio is streamed over an encrypted '
          'connection to Google\'s Gemini service, which detects the spoken language, '
          'transcribes it, and translates it into your language in real time. '
          'Translation requires an internet connection — it does not happen on the device.'
    ),
    (
      'Is audio stored?',
      'No. Audio is processed in real time to produce the transcription and '
          'translation. The app never saves raw audio to your phone, and never '
          'stores audio in your account.'
    ),
    (
      'What text is stored',
      'Finalized translations (text only — the original sentence, its translation, '
          'and the detected language) are saved to your private translation history in '
          'your account. Only you can access your history, and you can delete '
          'individual sessions or everything at any time.'
    ),
    (
      'Your account',
      'Your account stores your name, email, and chosen translation language. '
          'Sign-in is handled by Firebase Authentication. Deleting your account from '
          'the Profile screen permanently removes your account and your entire '
          'translation history.'
    ),
    (
      'Who processes the data',
      'Speech recognition and translation are performed by Google\'s Gemini API '
          'acting as a processor. Account data and translation history are stored in '
          'Google Firebase. Data is always sent over encrypted connections and is used '
          'solely to provide your translations.'
    ),
    (
      'Local laws',
      'Laws about recording or transcribing conversations around you vary by country '
          'and region. You are responsible for using Sayvo in a lawful and '
          'respectful way — when in doubt, tell people nearby that translation is running.'
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 20, 0),
                child: Row(
                  children: [
                    const BackButton(color: AppColors.textPrimary),
                    Expanded(
                      child: Text('Privacy Policy',
                          style: theme.textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800)),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: [
            Text(
              'Privacy is a core feature of Sayvo, not an afterthought.',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            for (final (title, body) in _sections)
              AppGlassCard(
                margin: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: AppColors.electricCyan,
                          fontWeight: FontWeight.w800,
                        )),
                    const SizedBox(height: 6),
                    Text(body,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.55,
                          color: AppColors.textSecondary,
                        )),
                  ],
                ),
              ),
          ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

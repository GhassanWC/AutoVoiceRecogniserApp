import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/permissions/mic_permission_service.dart';
import '../../services/storage/settings_store.dart';
import '../../utils/languages.dart';

/// First-launch flow: pick your language, understand microphone access.
/// Deliberately minimal — no accounts, no source-language configuration.
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({super.key});

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  int _step = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: _step == 0
              ? _LanguageStep(onSelected: () => setState(() => _step = 1))
              : const _MicrophoneStep(),
        ),
      ),
    );
  }
}

class _LanguageStep extends StatelessWidget {
  const _LanguageStep({required this.onSelected});

  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = context.watch<SettingsController>().settings.targetLanguage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('What language do you understand?',
                  style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(
                'Everything spoken around you will be translated into this language. '
                'You can change it later in Settings.',
                style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: kTargetLanguages.length,
            itemBuilder: (context, index) {
              final language = kTargetLanguages[index];
              final isSelected = language.code == selected;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: ListTile(
                  onTap: () async {
                    await context.read<SettingsController>().setTargetLanguage(language.code);
                    onSelected();
                  },
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  tileColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                  leading: Text(language.flag, style: const TextStyle(fontSize: 28)),
                  title: Text(language.nativeName,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
                  subtitle: language.nativeName == language.name ? null : Text(language.name),
                  trailing: isSelected ? const Icon(Icons.check_circle) : null,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _MicrophoneStep extends StatelessWidget {
  const _MicrophoneStep();

  Future<void> _finish(BuildContext context, {required bool requestPermission}) async {
    final settings = context.read<SettingsController>();
    if (requestPermission) {
      await MicPermissionService().request();
      // Whatever the outcome, onboarding continues — the main screen handles
      // denied states gracefully and never nags with repeated prompts.
    }
    await settings.completeOnboarding();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Spacer(),
          Icon(Icons.mic_none_rounded, size: 96, color: theme.colorScheme.primary),
          const SizedBox(height: 24),
          Text('Microphone Access',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          Text(
            'This app uses your microphone only while Live Translation is active, '
            'so it can hear speech around you and translate it into your language.\n\n'
            'Listening starts only when you press “Start Listening” — never on its own.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.outline),
          ),
          const Spacer(),
          FilledButton(
            onPressed: () => _finish(context, requestPermission: true),
            child: const Text('Allow Microphone'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => _finish(context, requestPermission: false),
            child: const Text('Not Now'),
          ),
        ],
      ),
    );
  }
}

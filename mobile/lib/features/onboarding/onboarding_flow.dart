import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/permissions/mic_permission_service.dart';
import '../../services/storage/settings_store.dart';
import '../../theme/app_colors.dart';
import '../../utils/languages.dart';
import '../../widgets/components/app_background.dart';
import '../../widgets/components/gradient_button.dart';
import '../../widgets/components/language_selector_sheet.dart' show LanguageRow;
import '../auth/auth_widgets.dart' show BrandMark;

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
      body: AppBackground(
        child: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: _step == 0
                ? _LanguageStep(onSelected: () => setState(() => _step = 1))
                : const _MicrophoneStep(),
          ),
        ),
      ),
    );
  }
}

class _LanguageStep extends StatefulWidget {
  const _LanguageStep({required this.onSelected});

  final VoidCallback onSelected;

  @override
  State<_LanguageStep> createState() => _LanguageStepState();
}

class _LanguageStepState extends State<_LanguageStep> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = context.watch<SettingsController>().settings.targetLanguage;
    final languages = searchLanguages(_query);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('What language do you understand?',
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(
                'Everything spoken around you will be translated into this '
                'language. You can change it later in your Profile.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
          child: TextField(
            onChanged: (value) => setState(() => _query = value),
            decoration: const InputDecoration(
              hintText: 'Search languages',
              prefixIcon: Icon(Icons.search_rounded),
            ),
          ),
        ),
        Expanded(
          child: languages.isEmpty
              ? Center(
                  child: Text(
                    'No languages match "$_query"',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: AppColors.textSecondary),
                  ),
                )
              : ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: languages.length,
            itemBuilder: (context, index) {
              final language = languages[index];
              return LanguageRow(
                language: language,
                selected: language.code == selected,
                onTap: () async {
                  await context
                      .read<SettingsController>()
                      .setTargetLanguage(language.code);
                  widget.onSelected();
                },
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
          const Center(child: BrandMark(size: 96)),
          const SizedBox(height: 28),
          Text('Microphone Access',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          Text(
            'This app uses your microphone only while Live Translation is active, '
            'so it can hear speech around you and translate it into your language.\n\n'
            'Listening starts only when you tap the microphone — never on its own.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: AppColors.textSecondary, height: 1.55),
          ),
          const Spacer(),
          GradientButton(
            label: 'Allow Microphone',
            icon: Icons.mic_rounded,
            onPressed: () => _finish(context, requestPermission: true),
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

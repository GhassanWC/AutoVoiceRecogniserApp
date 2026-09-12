import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/app_settings.dart';
import '../../../services/native/live_translation_support.dart';
import '../../../services/storage/settings_store.dart';
import '../../../utils/languages.dart';
import '../live_translation_controller.dart';

/// The native engine's language control on the main screen — Phase 3:
/// the user picks ONLY the target language; the source language is
/// AUTOMATIC (detected per utterance by the on-device detector).
///
/// Idle:
///   Translate to: [ 🇸🇦 Arabic ▾ ]     Source language: Automatic
///
/// While listening:
///   Auto-detecting the spoken language   →   Arabic
///
/// (The old "Listen for" multi-select lives on only as a Developer tool.)
class ListenLanguageBar extends StatelessWidget {
  const ListenLanguageBar({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>().settings;
    final controller = context.watch<LiveTranslationController>();
    if (settings.translationEngine != TranslationEngine.onDevice ||
        settings.mockMode) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final targetName =
        languageForCode(settings.targetLanguage)?.name ?? settings.targetLanguage;

    if (controller.state != ListeningState.idle) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
        child: Text(
          'Auto-detecting the spoken language   →   $targetName',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.center,
        children: [
          Text('Translate to:', style: theme.textTheme.bodySmall),
          ActionChip(
            avatar: Text(languageForCode(settings.targetLanguage)?.flag ?? '🌐'),
            label: Text(targetName),
            onPressed: () => _pickTarget(context),
          ),
          Text('Source language: Automatic', style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  /// Target language picker (same catalog as Settings → My Language).
  Future<void> _pickTarget(BuildContext context) async {
    final controller = context.read<SettingsController>();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (_, scroll) => ListView(
          controller: scroll,
          children: [
            for (final language in kTargetLanguages)
              ListTile(
                leading: Text(language.flag, style: const TextStyle(fontSize: 24)),
                title: Text(language.nativeName),
                subtitle: language.nativeName == language.name
                    ? null
                    : Text(language.name),
                trailing: controller.settings.targetLanguage == language.code
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () {
                  controller.setTargetLanguage(language.code);
                  Navigator.pop(sheetContext);
                },
              ),
          ],
        ),
      ),
    );
    // New utterances use the new target; translation pair statuses refresh.
    if (!context.mounted) return;
    unawaited(sharedLiveTranslationSupport.refresh(
      targetLanguage: controller.settings.targetLanguage,
      sourceLanguages: const ['en'],
    ));
  }
}

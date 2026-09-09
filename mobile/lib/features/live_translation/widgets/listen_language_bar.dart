import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/app_settings.dart';
import '../../../services/native/live_translation_support.dart';
import '../../../services/storage/settings_store.dart';
import '../../../utils/languages.dart';
import '../live_translation_controller.dart';
import 'language_picker_sheet.dart';

/// The native engine's language controls on the main screen.
///
/// Idle:
///   Translate to: [ 🇸🇦 Arabic ▾ ]
///   Listen for:   [ English ✓ ] [ Thai ↓ ] [ + Add language ]
///
/// While listening:
///   Listening for: English • Thai   →   Arabic
///
/// The user picks the listening languages ONCE; every utterance is then
/// auto-detected among them. Only shown for the native on-device engine.
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
      final active = controller.activeLanguages.isEmpty
          ? settings.listenLanguages
          : controller.activeLanguages;
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
        child: Text(
          'Listening for: ${active.map(listenLanguageName).join(' • ')}'
          '   →   $targetName',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
      );
    }

    return ListenableBuilder(
      listenable: sharedLiveTranslationSupport,
      builder: (context, _) {
        final support = sharedLiveTranslationSupport.current;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('Translate to:', style: theme.textTheme.bodySmall),
                  ActionChip(
                    avatar: Text(
                        languageForCode(settings.targetLanguage)?.flag ?? '🌐'),
                    label: Text(targetName),
                    onPressed: () => _pickTarget(context),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('Listen for:', style: theme.textTheme.bodySmall),
                  for (final code in settings.listenLanguages)
                    InputChip(
                      avatar: _statusIcon(context, support?.statusFor(code)),
                      label: Text(listenLanguageName(code)),
                      onPressed: () => showListenLanguagePicker(context),
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.add_rounded, size: 18),
                    label: Text(settings.listenLanguages.isEmpty
                        ? 'Add languages'
                        : 'Add language'),
                    onPressed: () => showListenLanguagePicker(context),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget? _statusIcon(BuildContext context, String? status) => switch (status) {
        'ready' => const Icon(Icons.check_circle_rounded,
            size: 18, color: Colors.green),
        'downloadRequired' =>
          const Icon(Icons.download_for_offline_outlined, size: 18),
        'unsupported' => Icon(Icons.error_outline_rounded,
            size: 18, color: Theme.of(context).colorScheme.error),
        _ => null,
      };

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
    // Changing the target NEVER touches the listening selection; only the
    // translation pair statuses need re-probing.
    if (!context.mounted) return;
    unawaited(sharedLiveTranslationSupport.refresh(
      targetLanguage: controller.settings.targetLanguage,
      sourceLanguages: controller.settings.listenLanguages,
    ));
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/app_settings.dart';
import '../../services/native/language_id.dart';
import '../../services/native/live_translation_support.dart';
import '../../services/permissions/mic_diagnostics.dart';
import '../../services/storage/history_store.dart';
import '../live_translation/widgets/language_picker_sheet.dart';
import '../live_translation/widgets/unsupported_dialog.dart';
import 'languages_screen.dart';
import '../../services/storage/settings_store.dart';
import '../../utils/languages.dart';
import 'privacy_policy_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<SettingsController>();
    final settings = controller.settings;
    final language = languageForCode(settings.targetLanguage);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _SectionHeader('Translation'),
          ListTile(
            leading: const Icon(Icons.translate_rounded),
            title: const Text('My Language'),
            subtitle: Text(language == null
                ? settings.targetLanguage
                : '${language.flag}  ${language.name}'),
            onTap: () => _pickLanguage(context, controller),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.subtitles_outlined),
            title: const Text('Show original speech'),
            subtitle: const Text('Display what was said, under the translation'),
            value: settings.showOriginalText,
            onChanged: (value) =>
                controller.update((s) => s.copyWith(showOriginalText: value)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.schedule_rounded),
            title: const Text('Show timestamps'),
            value: settings.showTimestamps,
            onChanged: (value) =>
                controller.update((s) => s.copyWith(showTimestamps: value)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.label_outline_rounded),
            title: const Text('Show language labels'),
            value: settings.showLanguageLabels,
            onChanged: (value) =>
                controller.update((s) => s.copyWith(showLanguageLabels: value)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.volume_up_outlined),
            title: const Text('Speak translations'),
            subtitle: const Text('Read translations aloud (Earphone Mode)'),
            value: settings.autoSpeak,
            onChanged: (value) => controller.update((s) => s.copyWith(autoSpeak: value)),
          ),
          const Divider(),
          const _SectionHeader('Privacy'),
          SwitchListTile(
            secondary: const Icon(Icons.save_outlined),
            title: const Text('Save translation history'),
            subtitle: const Text('Keep conversations on this device. Off by default. '
                'Audio is never saved.'),
            value: settings.saveHistory,
            onChanged: (value) => controller.update((s) => s.copyWith(saveHistory: value)),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded),
            title: const Text('Delete history'),
            onTap: () => _deleteHistory(context),
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Privacy Policy'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const PrivacyPolicyScreen()),
            ),
          ),
          const Divider(),
          const _SectionHeader('Appearance'),
          ListTile(
            leading: const Icon(Icons.brightness_6_outlined),
            title: const Text('Theme'),
            trailing: SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('Auto')),
                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
              ],
              selected: {settings.themeMode},
              onSelectionChanged: (selection) => controller.setThemeMode(selection.first),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.format_size_rounded),
            title: const Text('Text Size'),
            subtitle: Text(settings.textSize.label),
            onTap: () => _pickTextSize(context, controller),
          ),
          const Divider(),
          const _SectionHeader('Developer'),
          SwitchListTile(
            secondary: const Icon(Icons.smart_toy_outlined),
            title: const Text('Demo Mode'),
            subtitle: const Text('Generate a fake conversation — no microphone or server needed'),
            value: settings.mockMode,
            onChanged: (value) => controller.update((s) => s.copyWith(mockMode: value)),
          ),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Server URL'),
            subtitle: Text(settings.serverUrl.isEmpty ? 'Default' : settings.serverUrl),
            onTap: () => _editServerUrl(context, controller),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.troubleshoot_outlined),
            title: const Text('Diagnostics Logging'),
            subtitle: const Text('Log VAD levels and translation pipeline details to the console'),
            value: settings.developerDiagnostics,
            onChanged: (value) => controller.update((s) => s.copyWith(developerDiagnostics: value)),
          ),
          ListTile(
            leading: const Icon(Icons.graphic_eq_rounded),
            title: const Text('Test Language Detection'),
            subtitle: const Text('Speak one sentence — the on-device detector '
                'names the language (no speech recognition involved)'),
            onTap: () => _testLanguageDetection(context),
          ),
          ListTile(
            leading: const Icon(Icons.record_voice_over_outlined),
            title: const Text('Test Detect + Transcribe'),
            subtitle: const Text('Phase 2: detect the language, then run ONE '
                'Apple recognizer for it — no translation'),
            onTap: () => _testDetectTranscribe(context),
          ),
          ListTile(
            leading: const Icon(Icons.mic_none_rounded),
            title: const Text('Test Microphone Permission'),
            subtitle: const Text(
                'Native iOS permission state + 2-second capture — no Whisper involved'),
            onTap: () => _testMicPermission(context),
          ),
          ListTile(
            leading: const Icon(Icons.psychology_outlined),
            title: const Text('Translation Engine'),
            subtitle: Text(settings.translationEngine == TranslationEngine.onDevice
                ? 'Native on-device — the phone\'s own speech + translation; '
                    'audio never leaves the device'
                : 'Cloud (legacy/testing)'),
            onTap: () => _pickEngine(context, controller),
          ),
          ListTile(
            leading: const Icon(Icons.hearing_rounded),
            title: const Text('Listening Languages'),
            subtitle: Text(settings.listenLanguages.isEmpty
                ? 'None selected — add languages to listen for'
                : settings.listenLanguages.map(listenLanguageName).join(', ')),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const LanguagesScreen()),
            ),
          ),
          _SupportStatusTile(
            targetLanguage: settings.targetLanguage,
            listenLanguages: settings.listenLanguages,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// Phase 2 proof: utterance → detector → ONE Apple recognizer → text.
  Future<void> _testDetectTranscribe(BuildContext context) async {
    final navigator = Navigator.of(context);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(
              child: Text('SPEAK ONE CLEAR SENTENCE now…\n\n'
                  'The detector identifies the language, then one Apple '
                  'recognizer transcribes it (5-second capture).'),
            ),
          ],
        ),
      ),
    ));

    final report = await runDetectTranscribeTest();

    navigator.pop(); // close the progress dialog
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(report.passed
            ? 'Detect + Transcribe: PASS'
            : 'Detect + Transcribe: FAILED'),
        content: SingleChildScrollView(
          child: SelectableText(
            report.details,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// The ISOLATED audio language-ID test the new architecture is gated on:
  /// capture one spoken sentence, run ONLY the VoxLingua107 detector, and
  /// show language + confidence + top alternatives. Test English, Arabic,
  /// Hindi, Thai and Bengali on the real iPhone before the pipeline adopts it.
  Future<void> _testLanguageDetection(BuildContext context) async {
    final navigator = Navigator.of(context);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(
              child: Text('SPEAK ONE CLEAR SENTENCE now…\n\n'
                  'The on-device detector identifies the language from the '
                  'audio itself (5 seconds).'),
            ),
          ],
        ),
      ),
    ));

    final report = await runLanguageIdTest();

    navigator.pop(); // close the progress dialog
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(report.passed
            ? 'Language detection: PASS'
            : 'Language detection: FAILED'),
        content: SingleChildScrollView(
          child: SelectableText(
            report.details,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Proves the microphone path with zero Whisper involvement: the native
  /// [MIC PERMISSION] block, then 2 seconds of real PCM → "Audio capture: PASS".
  Future<void> _testMicPermission(BuildContext context) async {
    final navigator = Navigator.of(context);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(child: Text('Checking permission + capturing 2 seconds of audio…')),
          ],
        ),
      ),
    ));

    final report = await runMicPermissionTest();

    navigator.pop(); // close the progress dialog
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(report.passed ? 'Microphone: PASS' : 'Microphone: FAILED'),
        content: SingleChildScrollView(
          child: SelectableText(
            report.details,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }


  void _pickEngine(BuildContext context, SettingsController controller) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Translation Engine'),
        children: [
          for (final engine in TranslationEngine.values)
            ListTile(
              title: Text(engine.label),
              subtitle: Text(engine == TranslationEngine.onDevice
                  ? 'Production goal. The phone\'s own on-device speech '
                      'recognition + translation. No cloud, no API keys.'
                  : 'Kept temporarily for comparison/testing.'),
              trailing: controller.settings.translationEngine == engine
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () {
                controller.update((s) => s.copyWith(translationEngine: engine));
                Navigator.pop(dialogContext);
              },
            ),
        ],
      ),
    );
  }

  void _pickLanguage(BuildContext context, SettingsController controller) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (_, scrollController) => ListView(
          controller: scrollController,
          children: [
            for (final language in kTargetLanguages)
              ListTile(
                leading: Text(language.flag, style: const TextStyle(fontSize: 24)),
                title: Text(language.nativeName),
                subtitle: language.nativeName == language.name ? null : Text(language.name),
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
  }

  void _pickTextSize(BuildContext context, SettingsController controller) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final size in AppTextSize.values)
              ListTile(
                title: Text(size.label, textScaler: TextScaler.linear(size.scale)),
                trailing: controller.settings.textSize == size
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () {
                  controller.setTextSize(size);
                  Navigator.pop(sheetContext);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteHistory(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete all saved translation history?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed == true) {
      await HistoryStore().deleteAll();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('History deleted')));
      }
    }
  }

  Future<void> _editServerUrl(BuildContext context, SettingsController controller) async {
    final textController = TextEditingController(text: controller.settings.serverUrl);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Server URL'),
        content: TextField(
          controller: textController,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'http://192.168.1.10:8080',
            helperText: 'Leave empty for the default (emulator loopback).',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, textController.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null) {
      await controller.update((s) => s.copyWith(serverUrl: result));
    }
  }
}

/// "On-device Live Translation — Status: Supported ✓ / Not supported".
/// The status comes from the shared capability probe (real OS answers, not
/// version guessing); tapping shows the reason, with Check Again to re-probe.
class _SupportStatusTile extends StatelessWidget {
  const _SupportStatusTile({
    required this.targetLanguage,
    required this.listenLanguages,
  });

  final String targetLanguage;
  final List<String> listenLanguages;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sharedLiveTranslationSupport,
      builder: (context, _) {
        final service = sharedLiveTranslationSupport;
        final support = service.current;
        if (support == null && !service.probing) {
          // First visit before the startup probe finished — kick one off.
          WidgetsBinding.instance.addPostFrameCallback((_) => service.ensure(
              targetLanguage: targetLanguage, sourceLanguages: listenLanguages));
        }
        final String status;
        if (support == null || service.probing) {
          status = 'Checking…';
        } else if (support.supported) {
          status = 'Status: Supported ✓';
        } else {
          status = 'Status: Not supported';
        }
        return ListTile(
          leading: Icon(
            support?.supported == true
                ? Icons.verified_outlined
                : Icons.privacy_tip_outlined,
            color: support == null
                ? null
                : support.supported
                    ? Colors.green
                    : Theme.of(context).colorScheme.error,
          ),
          title: const Text('On-device Live Translation'),
          subtitle: Text(status),
          onTap: () async {
            final current = await service.refresh(
                targetLanguage: targetLanguage, sourceLanguages: listenLanguages);
            if (!context.mounted) return;
            if (current.supported) {
              await _showStatusDialog(context, current);
            } else {
              await showLiveTranslationUnsupportedDialog(
                context,
                support: current,
                targetLanguage: targetLanguage,
                sourceLanguages: listenLanguages,
              );
            }
          },
        );
      },
    );
  }

  String _languageName(String code) => languageForCode(code)?.name ?? code;

  /// Per-language status ("Ready ✓" / "Download required" / "Unsupported"),
  /// the raw probe diagnostics, and — when models are pending — the
  /// "Prepare Live Translation" action that downloads them via the OS.
  Future<void> _showStatusDialog(
      BuildContext context, LiveTranslationSupport support) async {
    final codes = support.languageStatus.keys.toList()
      ..sort((a, b) => _languageName(a).compareTo(_languageName(b)));
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('On-device Live Translation'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final code in codes)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_languageName(code)),
                      Text(switch (support.languageStatus[code]) {
                        'ready' => 'Ready ✓',
                        'downloadRequired' => 'Download required',
                        _ => 'Unsupported',
                      }),
                    ],
                  ),
                ),
              const SizedBox(height: 10),
              Text('OS: ${support.osVersion}\n${support.reason}',
                  style: Theme.of(dialogContext).textTheme.bodySmall),
              if (support.speechDiagnostics.isNotEmpty) ...[
                const SizedBox(height: 10),
                SelectableText(
                  support.speechDiagnostics.join('\n'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (support.pendingDownloads.isNotEmpty)
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                _prepareLiveTranslation(context);
              },
              child: const Text('Prepare Live Translation'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Downloads the pending speech models through Apple's AssetInventory,
  /// with live progress, then RE-RUNS the capability check and shows the
  /// refreshed per-language status.
  Future<void> _prepareLiveTranslation(BuildContext context) async {
    final progress = ValueNotifier<SpeechAssetInstallProgress?>(null);
    var dismissed = false;
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: ValueListenableBuilder<SpeechAssetInstallProgress?>(
          valueListenable: progress,
          builder: (dialogContext, value, _) {
            final language = value?.language;
            final label = language == null
                ? 'Preparing Live Translation…'
                : 'Preparing ${_languageName(language)}… '
                    '${((value?.fraction ?? 0) * 100).toStringAsFixed(0)}%'
                    '${(value?.total ?? 0) > 1 ? '  (${(value?.completed ?? 0) + 1}/${value?.total})' : ''}';
            return Row(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 16),
                Expanded(child: Text(label)),
              ],
            );
          },
        ),
      ),
    ).whenComplete(() => dismissed = true));

    String? failure;
    final pending =
        sharedLiveTranslationSupport.current?.pendingDownloads ?? const [];
    try {
      await NativeSpeechAssets.install(
        languages: pending,
        onProgress: (value) => progress.value = value,
      );
    } catch (_) {
      final names = pending.map(_languageName).join(', ');
      failure = "$names couldn't be prepared. "
          'Check your internet connection and try again.';
    }
    // Installation changes the device's installed set — re-probe (required).
    final refreshed = await sharedLiveTranslationSupport.refresh(
        targetLanguage: targetLanguage, sourceLanguages: listenLanguages);
    if (!context.mounted) return;
    if (!dismissed) Navigator.of(context, rootNavigator: true).pop();
    if (failure != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failure)));
    }
    await _showStatusDialog(context, refreshed);
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

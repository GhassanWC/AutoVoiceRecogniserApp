import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/native/live_translation_support.dart';
import '../../../services/storage/settings_store.dart';
import '../../../utils/languages.dart';
import '../../settings/languages_screen.dart';

String listenLanguageName(String code) => languageForCode(code)?.name ?? code.toUpperCase();

String listenLanguageFlag(String code) => languageForCode(code)?.flag ?? '🌐';

/// "Select languages to listen for" — the multi-select picker.
///
/// The list of offerable languages comes from the device's REAL speech
/// inventory (SpeechTranscriber.supportedLocales via the capability probe),
/// never a hardcoded pretend-list; our catalog only contributes friendly
/// names and flags. Languages the device does not support are shown
/// disabled as "Not available on this device". Each entry shows its
/// readiness (Ready ✓ / Download required).
Future<void> showListenLanguagePicker(BuildContext context) async {
  final settingsController = context.read<SettingsController>();
  // Fresh inventory for accurate statuses (cached result shown meanwhile).
  unawaited(sharedLiveTranslationSupport.refresh(
    targetLanguage: settingsController.settings.targetLanguage,
    sourceLanguages: settingsController.settings.listenLanguages,
  ));

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => const _ListenLanguagePicker(),
  );

  // Selection may have changed — refresh statuses for the new set.
  unawaited(sharedLiveTranslationSupport.refresh(
    targetLanguage: settingsController.settings.targetLanguage,
    sourceLanguages: settingsController.settings.listenLanguages,
  ));
}

class _ListenLanguagePicker extends StatefulWidget {
  const _ListenLanguagePicker();

  @override
  State<_ListenLanguagePicker> createState() => _ListenLanguagePickerState();
}

class _ListenLanguagePickerState extends State<_ListenLanguagePicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<SettingsController>();
    final selected = controller.settings.listenLanguages;

    return ListenableBuilder(
      listenable: sharedLiveTranslationSupport,
      builder: (context, _) {
        final support = sharedLiveTranslationSupport.current;
        // The device inventory is the source of truth; the display catalog
        // only decorates it. Codes outside our catalog still appear.
        final offered = <String>{...?support?.supportedLanguages, ...selected};
        final matches = offered.where((code) {
          if (_query.isEmpty) return true;
          final query = _query.toLowerCase();
          return listenLanguageName(code).toLowerCase().contains(query) ||
              (languageForCode(code)?.nativeName.toLowerCase().contains(query) ??
                  false) ||
              code.toLowerCase().contains(query);
        }).toList()
          ..sort((a, b) => listenLanguageName(a).compareTo(listenLanguageName(b)));
        final selectedMatches =
            matches.where(selected.contains).toList(growable: false);
        final availableMatches =
            matches.where((code) => !selected.contains(code)).toList(growable: false);

        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          builder: (_, scroll) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Column(
                  children: [
                    Text('Select languages to listen for',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 10),
                    TextField(
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search_rounded),
                        hintText: 'Search languages…',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (value) => setState(() => _query = value.trim()),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: support == null
                    ? const Center(child: CircularProgressIndicator())
                    : ListView(
                        controller: scroll,
                        children: [
                          if (selectedMatches.isNotEmpty)
                            const _PickerHeader('Selected'),
                          for (final code in selectedMatches)
                            _tile(context, controller, support, code,
                                isSelected: true),
                          const _PickerHeader('Available languages'),
                          for (final code in availableMatches)
                            _tile(context, controller, support, code,
                                isSelected: false),
                          const SizedBox(height: 24),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _tile(
    BuildContext context,
    SettingsController controller,
    LiveTranslationSupport support,
    String code, {
    required bool isSelected,
  }) {
    final status = support.statusFor(code);
    final unsupported = status == 'unsupported';
    return ListTile(
      enabled: !unsupported || isSelected,
      leading: Text(listenLanguageFlag(code), style: const TextStyle(fontSize: 24)),
      title: Text(listenLanguageName(code)),
      subtitle: Text(switch (status) {
        'ready' => 'Ready ✓',
        'downloadRequired' => 'Download required',
        _ => 'Not available on this device',
      }),
      trailing: isSelected ? const Icon(Icons.check_rounded) : null,
      onTap: unsupported && !isSelected
          ? null
          : () => _toggle(context, controller, support, code, isSelected),
    );
  }

  Future<void> _toggle(
    BuildContext context,
    SettingsController controller,
    LiveTranslationSupport support,
    String code,
    bool isSelected,
  ) async {
    final selected = List<String>.of(controller.settings.listenLanguages);
    if (isSelected) {
      selected.remove(code);
      await controller.update((s) => s.copyWith(listenLanguages: selected));
      return;
    }
    // Reservation-capacity gate: the phone can only keep N speech languages
    // ready at once (N = AssetInventory.maximumReservedLocales, live value).
    final max = support.maximumReservedLocales;
    final needsDownload = support.statusFor(code) == 'downloadRequired';
    if (needsDownload && max > 0 && support.reservedLocales.length >= max) {
      await _showLimitDialog(context, code, max);
      return;
    }
    selected.add(code);
    await controller.update((s) => s.copyWith(listenLanguages: selected));
  }

  Future<void> _showLimitDialog(BuildContext context, String code, int max) =>
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Language limit reached'),
          content: Text(
              'Your iPhone can keep $max speech languages ready for Live '
              'Translation at once.\n\nRemove one language before adding '
              '${listenLanguageName(code)}.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => const LanguagesScreen()),
                );
              },
              child: const Text('Manage Languages'),
            ),
          ],
        ),
      );
}

class _PickerHeader extends StatelessWidget {
  const _PickerHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
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

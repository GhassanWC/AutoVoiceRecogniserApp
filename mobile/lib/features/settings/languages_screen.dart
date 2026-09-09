import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/native/live_translation_support.dart';
import '../../services/storage/settings_store.dart';
import '../../utils/languages.dart';
import '../live_translation/widgets/language_picker_sheet.dart';

/// Settings → Languages: manage the "Listen for" languages and their speech
/// models. Shows each selected language's real status (Ready ✓ / Download
/// required / Not available), offers Download and Remove, and — when a
/// language holds one of the phone's limited asset slots — lets the USER
/// decide whether to free it. Nothing is removed or released silently.
class LanguagesScreen extends StatefulWidget {
  const LanguagesScreen({super.key});

  @override
  State<LanguagesScreen> createState() => _LanguagesScreenState();
}

class _LanguagesScreenState extends State<LanguagesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final settings = context.read<SettingsController>().settings;
    await sharedLiveTranslationSupport.refresh(
      targetLanguage: settings.targetLanguage,
      sourceLanguages: settings.listenLanguages,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<SettingsController>();
    final settings = controller.settings;
    final target = languageForCode(settings.targetLanguage);

    return Scaffold(
      appBar: AppBar(title: const Text('Languages')),
      body: ListenableBuilder(
        listenable: sharedLiveTranslationSupport,
        builder: (context, _) {
          final support = sharedLiveTranslationSupport.current;
          return ListView(
            children: [
              ListTile(
                leading: const Icon(Icons.translate_rounded),
                title: const Text('Translate to'),
                subtitle: Text(target == null
                    ? settings.targetLanguage
                    : '${target.flag}  ${target.name}'),
              ),
              if (support != null && support.maximumReservedLocales > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Your iPhone can keep ${support.maximumReservedLocales} '
                    'speech languages ready at once.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  'Listening Languages',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w800,
                      ),
                ),
              ),
              for (final code in settings.listenLanguages)
                _languageTile(context, controller, support, code),
              ListTile(
                leading: const Icon(Icons.add_rounded),
                title: const Text('Add language'),
                onTap: () async {
                  await showListenLanguagePicker(context);
                  await _refresh();
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _languageTile(
    BuildContext context,
    SettingsController controller,
    LiveTranslationSupport? support,
    String code,
  ) {
    final status = support?.statusFor(code) ?? 'unknown';
    return ListTile(
      leading: Text(listenLanguageFlag(code), style: const TextStyle(fontSize: 24)),
      title: Text(listenLanguageName(code)),
      subtitle: Text(switch (status) {
        'ready' => 'Ready ✓',
        'downloadRequired' => 'Download required',
        'unsupported' => 'Not available on this device',
        _ => 'Checking…',
      }),
      trailing: PopupMenuButton<String>(
        onSelected: (action) => switch (action) {
          'download' => _download(code),
          _ => _remove(context, controller, support, code),
        },
        itemBuilder: (_) => [
          if (status == 'downloadRequired')
            const PopupMenuItem(value: 'download', child: Text('Download')),
          const PopupMenuItem(value: 'remove', child: Text('Remove')),
        ],
      ),
    );
  }

  /// Downloads one language's speech model with visible progress.
  Future<void> _download(String code) async {
    final progress = ValueNotifier<double>(0);
    var dismissed = false;
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, value, __) => Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 16),
              Expanded(
                child: Text('Downloading ${listenLanguageName(code)} speech… '
                    '${(value * 100).toStringAsFixed(0)}%'),
              ),
            ],
          ),
        ),
      ),
    ).whenComplete(() => dismissed = true));

    String? failure;
    try {
      await NativeSpeechAssets.install(
        languages: [code],
        onProgress: (value) => progress.value = value.fraction,
      );
    } catch (_) {
      failure = "${listenLanguageName(code)} couldn't be prepared. "
          'Check your internet connection and try again.';
    }
    await _refresh();
    if (!mounted) return;
    if (!dismissed) Navigator.of(context, rootNavigator: true).pop();
    if (failure != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failure)));
    }
  }

  /// Removes a language from the listening list; when it holds one of the
  /// phone's asset slots, the USER chooses whether to free the slot too.
  Future<void> _remove(
    BuildContext context,
    SettingsController controller,
    LiveTranslationSupport? support,
    String code,
  ) async {
    final selected = List<String>.of(controller.settings.listenLanguages)
      ..remove(code);
    await controller.update((s) => s.copyWith(listenLanguages: selected));

    final holdsSlot = support?.reservedLocales
            .any((id) => id.toLowerCase().startsWith(code.toLowerCase())) ??
        false;
    if (!holdsSlot || !context.mounted) {
      await _refresh();
      return;
    }
    final release = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Free the ${listenLanguageName(code)} download slot?'),
        content: const Text(
            'This language holds one of the speech-model slots your iPhone '
            'can keep ready. Freeing it makes room for another language; '
            'keeping it means re-adding this language later is instant.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Free slot'),
          ),
        ],
      ),
    );
    if (release == true) {
      await NativeSpeechAssets.release(language: code);
    }
    await _refresh();
  }
}

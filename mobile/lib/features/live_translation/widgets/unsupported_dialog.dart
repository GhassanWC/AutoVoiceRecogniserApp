import 'package:flutter/material.dart';

import '../../../services/native/live_translation_support.dart';

/// The one honest modal for unsupported / partially supported devices.
///
/// Wording rules (product requirements):
///  - If an OS UPDATE could fix it → "Update required" with the current
///    version. NEVER tell the user their phone is permanently unsupported
///    when updating could solve it.
///  - Speech works but detection/translation doesn't → the "not fully
///    available" wording.
///  - Otherwise → the simple generic message.
/// Buttons: Check Again (re-probes) and OK. No session ever starts from here.
Future<void> showLiveTranslationUnsupportedDialog(
  BuildContext context, {
  required LiveTranslationSupport support,
  required String targetLanguage,
  List<String> sourceLanguages = const ['en'],
}) async {
  final String title;
  final String body;
  if (support.updateRequired) {
    title = 'Update required';
    body = 'Live Translation requires a newer version of iOS/Android. '
        'Your current version is ${support.osVersion}.';
  } else if (support.partiallySupported) {
    title = 'Live Translation is not fully available';
    body = 'Your device supports speech recognition, but one or more '
        'required on-device language features are unavailable.\n\n'
        '${support.reason}';
  } else {
    title = '⚠️ Live Translation unavailable';
    body = "Your device doesn't support the on-device features required for "
        'Live Translation. Update your phone\'s software and try again.';
  }

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () async {
            final navigator = Navigator.of(dialogContext);
            final messenger = ScaffoldMessenger.of(context);
            final refreshed = await sharedLiveTranslationSupport.refresh(
                targetLanguage: targetLanguage, sourceLanguages: sourceLanguages);
            navigator.pop();
            messenger.showSnackBar(SnackBar(
              content: Text(refreshed.supported
                  ? 'Live Translation is supported ✓'
                  : 'Still unavailable — ${refreshed.reason}'),
            ));
          },
          child: const Text('Check Again'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

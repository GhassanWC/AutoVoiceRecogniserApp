import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'features/live_translation/live_translation_controller.dart';
import 'services/local/legacy_model_cleanup.dart';
import 'services/storage/settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsController(SettingsStore());
  await settings.load();
  // Fire-and-forget: reclaim the removed whisper.cpp engine's model storage.
  unawaited(deleteLegacyGgmlModels());
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsController>.value(value: settings),
        ChangeNotifierProvider<LiveTranslationController>(
          create: (_) => LiveTranslationController(settings: settings),
        ),
      ],
      child: const LiveTranslatorApp(),
    ),
  );
}

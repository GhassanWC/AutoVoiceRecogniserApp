import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'features/live_translation/live_translation_controller.dart';
import 'services/storage/settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsController(SettingsStore());
  await settings.load();
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

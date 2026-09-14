import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'features/auth/auth_gate.dart';
import 'models/app_settings.dart';
import 'services/storage/settings_store.dart';
import 'theme/app_theme.dart';

class LiveTranslatorApp extends StatelessWidget {
  const LiveTranslatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>().settings;
    return MaterialApp(
      title: 'Live Translator',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: settings.themeMode,
      builder: (context, child) {
        // User-selected text size stacks with the system's dynamic type,
        // clamped so the layout stays usable at the extremes.
        final media = MediaQuery.of(context);
        final combined =
            (media.textScaler.scale(1.0) * settings.textSize.scale).clamp(0.8, 2.2);
        return MediaQuery(
          data: media.copyWith(textScaler: TextScaler.linear(combined)),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const AuthGate(),
    );
  }
}

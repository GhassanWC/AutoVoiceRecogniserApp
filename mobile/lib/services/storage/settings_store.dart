import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/app_settings.dart';

class SettingsStore {
  static const _key = 'app.settings.v1';

  Future<AppSettings> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return const AppSettings();
      return AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const AppSettings();
    }
  }

  Future<void> save(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(settings.toJson()));
  }
}

/// App-wide settings state. Everything the UI needs is exposed as one
/// immutable [AppSettings] value plus mutation helpers that persist.
///
/// The target language is a local mirror of the signed-in user's Firestore
/// profile: [setTargetLanguage] (user action) also notifies
/// [onTargetLanguageChanged] so the profile is updated, while
/// [applyRemoteTargetLanguage] (profile → local) deliberately does not.
class SettingsController extends ChangeNotifier {
  SettingsController(this._store);

  final SettingsStore _store;
  AppSettings _settings = const AppSettings();
  AppSettings get settings => _settings;

  /// Set by AuthController to push user-initiated changes to Firestore.
  Future<void> Function(String code)? onTargetLanguageChanged;

  Future<void> load() async {
    _settings = await _store.load();
    notifyListeners();
  }

  Future<void> update(AppSettings Function(AppSettings) change) async {
    _settings = change(_settings);
    notifyListeners();
    await _store.save(_settings);
  }

  Future<void> setTargetLanguage(String code) async {
    await update((s) => s.copyWith(targetLanguage: code));
    await onTargetLanguageChanged?.call(code);
  }

  /// The signed-in profile's preference arrived — mirror it locally without
  /// echoing it back to Firestore.
  Future<void> applyRemoteTargetLanguage(String code) =>
      update((s) => s.copyWith(targetLanguage: code));

  Future<void> completeOnboarding() => update((s) => s.copyWith(onboardingComplete: true));
  Future<void> setThemeMode(ThemeMode mode) => update((s) => s.copyWith(themeMode: mode));
  Future<void> setTextSize(AppTextSize size) => update((s) => s.copyWith(textSize: size));
}

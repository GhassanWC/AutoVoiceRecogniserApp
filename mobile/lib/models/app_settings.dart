import 'package:flutter/material.dart';

enum AppTextSize { small, medium, large, extraLarge }

/// A/B experiment: cloud pipeline vs fully on-device AI. With [onDevice]
/// selected there are NO OpenAI calls, NO backend speech API, NO cloud
/// translation, NO API keys involved — raw audio never leaves the iPhone.
enum TranslationEngine { openai, onDevice }

extension TranslationEngineLabel on TranslationEngine {
  String get label => switch (this) {
        TranslationEngine.openai => 'Cloud (legacy/testing)',
        TranslationEngine.onDevice => 'Native on-device',
      };
}

extension AppTextSizeScale on AppTextSize {
  double get scale => switch (this) {
        AppTextSize.small => 0.9,
        AppTextSize.medium => 1.0,
        AppTextSize.large => 1.15,
        AppTextSize.extraLarge => 1.3,
      };

  String get label => switch (this) {
        AppTextSize.small => 'Small',
        AppTextSize.medium => 'Medium',
        AppTextSize.large => 'Large',
        AppTextSize.extraLarge => 'Extra Large',
      };
}

class AppSettings {
  const AppSettings({
    this.targetLanguage = 'en',
    this.showOriginalText = true,
    this.showTimestamps = true,
    this.showLanguageLabels = true,
    this.autoSpeak = false,
    this.saveHistory = false,
    this.themeMode = ThemeMode.system,
    this.textSize = AppTextSize.medium,
    this.onboardingComplete = false,
    this.serverUrl = '',
    this.mockMode = false,
    this.developerDiagnostics = false,
    this.translationEngine = TranslationEngine.openai,
    this.onDeviceModel = 'large-v3-turbo-q5_0',
    this.listenLanguages = const ['en'],
  });

  final String targetLanguage;
  final bool showOriginalText;
  final bool showTimestamps;
  final bool showLanguageLabels;
  final bool autoSpeak;

  /// Privacy default: off — nothing is stored unless the user opts in.
  final bool saveHistory;
  final ThemeMode themeMode;
  final AppTextSize textSize;
  final bool onboardingComplete;

  /// Backend base URL; empty → platform default (emulator loopback).
  final String serverUrl;

  /// Demo mode: generates a fake conversation, no microphone, no network.
  final bool mockMode;

  /// Developer mode: log VAD and translation-pipeline diagnostics.
  final bool developerDiagnostics;

  /// A/B experiment: which engine drives live translation.
  final TranslationEngine translationEngine;

  /// Which offline Whisper model to use (key into the offline model catalog).
  final String onDeviceModel;

  /// Native on-device engine: the SOURCE languages the user wants Live
  /// Translator to LISTEN FOR ("Listen for: English, Thai…"). The user picks
  /// these once; each utterance is auto-detected among them. One language is
  /// perfectly valid (fast single-recognizer path); the first-run default is
  /// English only — never a silently-downloaded world list. Platform-neutral
  /// so Android reuses the same state later.
  final List<String> listenLanguages;

  AppSettings copyWith({
    String? targetLanguage,
    bool? showOriginalText,
    bool? showTimestamps,
    bool? showLanguageLabels,
    bool? autoSpeak,
    bool? saveHistory,
    ThemeMode? themeMode,
    AppTextSize? textSize,
    bool? onboardingComplete,
    String? serverUrl,
    bool? mockMode,
    bool? developerDiagnostics,
    TranslationEngine? translationEngine,
    String? onDeviceModel,
    List<String>? listenLanguages,
  }) {
    return AppSettings(
      targetLanguage: targetLanguage ?? this.targetLanguage,
      showOriginalText: showOriginalText ?? this.showOriginalText,
      showTimestamps: showTimestamps ?? this.showTimestamps,
      showLanguageLabels: showLanguageLabels ?? this.showLanguageLabels,
      autoSpeak: autoSpeak ?? this.autoSpeak,
      saveHistory: saveHistory ?? this.saveHistory,
      themeMode: themeMode ?? this.themeMode,
      textSize: textSize ?? this.textSize,
      onboardingComplete: onboardingComplete ?? this.onboardingComplete,
      serverUrl: serverUrl ?? this.serverUrl,
      mockMode: mockMode ?? this.mockMode,
      developerDiagnostics: developerDiagnostics ?? this.developerDiagnostics,
      translationEngine: translationEngine ?? this.translationEngine,
      onDeviceModel: onDeviceModel ?? this.onDeviceModel,
      listenLanguages: listenLanguages ?? this.listenLanguages,
    );
  }

  Map<String, dynamic> toJson() => {
        'targetLanguage': targetLanguage,
        'showOriginalText': showOriginalText,
        'showTimestamps': showTimestamps,
        'showLanguageLabels': showLanguageLabels,
        'autoSpeak': autoSpeak,
        'saveHistory': saveHistory,
        'themeMode': themeMode.name,
        'textSize': textSize.name,
        'onboardingComplete': onboardingComplete,
        'serverUrl': serverUrl,
        'mockMode': mockMode,
        'developerDiagnostics': developerDiagnostics,
        'translationEngine': translationEngine.name,
        'onDeviceModel': onDeviceModel,
        'listenLanguages': listenLanguages,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        targetLanguage: json['targetLanguage'] as String? ?? 'en',
        showOriginalText: json['showOriginalText'] as bool? ?? true,
        showTimestamps: json['showTimestamps'] as bool? ?? true,
        showLanguageLabels: json['showLanguageLabels'] as bool? ?? true,
        autoSpeak: json['autoSpeak'] as bool? ?? false,
        saveHistory: json['saveHistory'] as bool? ?? false,
        themeMode: ThemeMode.values.asNameMap()[json['themeMode']] ?? ThemeMode.system,
        textSize: AppTextSize.values.asNameMap()[json['textSize']] ?? AppTextSize.medium,
        onboardingComplete: json['onboardingComplete'] as bool? ?? false,
        serverUrl: json['serverUrl'] as String? ?? '',
        mockMode: json['mockMode'] as bool? ?? false,
        developerDiagnostics: json['developerDiagnostics'] as bool? ?? false,
        translationEngine: TranslationEngine.values.asNameMap()[json['translationEngine']] ??
            TranslationEngine.openai,
        onDeviceModel: json['onDeviceModel'] as String? ?? 'large-v3-turbo-q5_0',
        listenLanguages: [
          for (final code in json['listenLanguages'] as List<dynamic>? ?? ['en'])
            '$code'
        ],
      );
}

import 'package:flutter/material.dart';

enum AppTextSize { small, medium, large, extraLarge }

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

/// Local display/preferences state. The target language is mirrored here for
/// instant startup, but its source of truth is the signed-in user's Firestore
/// profile document (users/{uid}.targetLanguageCode).
class AppSettings {
  const AppSettings({
    this.targetLanguage = 'en',
    this.showOriginalText = true,
    this.showTimestamps = true,
    this.showLanguageLabels = true,
    this.autoSpeak = true,
    this.themeMode = ThemeMode.system,
    this.textSize = AppTextSize.medium,
    this.onboardingComplete = false,
  });

  final String targetLanguage;
  final bool showOriginalText;
  final bool showTimestamps;
  final bool showLanguageLabels;

  /// Play Gemini's spoken translation through the speaker.
  final bool autoSpeak;
  final ThemeMode themeMode;
  final AppTextSize textSize;
  final bool onboardingComplete;

  AppSettings copyWith({
    String? targetLanguage,
    bool? showOriginalText,
    bool? showTimestamps,
    bool? showLanguageLabels,
    bool? autoSpeak,
    ThemeMode? themeMode,
    AppTextSize? textSize,
    bool? onboardingComplete,
  }) {
    return AppSettings(
      targetLanguage: targetLanguage ?? this.targetLanguage,
      showOriginalText: showOriginalText ?? this.showOriginalText,
      showTimestamps: showTimestamps ?? this.showTimestamps,
      showLanguageLabels: showLanguageLabels ?? this.showLanguageLabels,
      autoSpeak: autoSpeak ?? this.autoSpeak,
      themeMode: themeMode ?? this.themeMode,
      textSize: textSize ?? this.textSize,
      onboardingComplete: onboardingComplete ?? this.onboardingComplete,
    );
  }

  Map<String, dynamic> toJson() => {
        'targetLanguage': targetLanguage,
        'showOriginalText': showOriginalText,
        'showTimestamps': showTimestamps,
        'showLanguageLabels': showLanguageLabels,
        'autoSpeak': autoSpeak,
        'themeMode': themeMode.name,
        'textSize': textSize.name,
        'onboardingComplete': onboardingComplete,
      };

  /// Fields from removed pre-Gemini settings (translationEngine, serverUrl,
  /// mockMode, saveHistory, …) are deliberately ignored on load.
  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        targetLanguage: json['targetLanguage'] as String? ?? 'en',
        showOriginalText: json['showOriginalText'] as bool? ?? true,
        showTimestamps: json['showTimestamps'] as bool? ?? true,
        showLanguageLabels: json['showLanguageLabels'] as bool? ?? true,
        autoSpeak: json['autoSpeak'] as bool? ?? true,
        themeMode: ThemeMode.values.asNameMap()[json['themeMode']] ?? ThemeMode.system,
        textSize: AppTextSize.values.asNameMap()[json['textSize']] ?? AppTextSize.medium,
        onboardingComplete: json['onboardingComplete'] as bool? ?? false,
      );
}

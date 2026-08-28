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
      );
}

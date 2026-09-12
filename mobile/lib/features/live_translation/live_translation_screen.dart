import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/app_settings.dart';
import '../../services/native/live_translation_support.dart';
import '../../services/storage/settings_store.dart';
import '../../utils/languages.dart';
import '../history/history_screen.dart';
import '../settings/settings_screen.dart';
import 'live_translation_controller.dart';
import 'widgets/listen_language_bar.dart';
import 'widgets/listening_indicator.dart';
import 'widgets/message_bubble.dart';
import 'widgets/unsupported_dialog.dart';

class LiveTranslationScreen extends StatefulWidget {
  const LiveTranslationScreen({super.key});

  @override
  State<LiveTranslationScreen> createState() => _LiveTranslationScreenState();
}

class _LiveTranslationScreenState extends State<LiveTranslationScreen> {
  final ScrollController _scroll = ScrollController();
  StreamSubscription<String>? _noticeSubscription;
  int _renderedMessageCount = 0;
  bool _showNewMessagePill = false;

  LiveTranslationController get _controller => context.read<LiveTranslationController>();

  @override
  void initState() {
    super.initState();
    _noticeSubscription = _controller.notices.listen((notice) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(notice), duration: const Duration(seconds: 3)));
    });
    _controller.addListener(_handleControllerChanged);
    _scroll.addListener(() {
      if (_isNearBottom && _showNewMessagePill) {
        setState(() => _showNewMessagePill = false);
      }
    });
    // App-startup capability probe (required): the Start button and the
    // Settings status row reflect real device capability before first use.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final settings = context.read<SettingsController>().settings;
      sharedLiveTranslationSupport.ensure(
        targetLanguage: settings.targetLanguage,
        sourceLanguages: const ['en'], // source is automatic
      );
    });
  }

  bool get _isNearBottom =>
      !_scroll.hasClients || _scroll.position.extentAfter < 120;

  void _handleControllerChanged() {
    final count = _controller.messages.length;
    if (count > _renderedMessageCount) {
      _renderedMessageCount = count;
      if (_isNearBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      } else if (!_showNewMessagePill && mounted) {
        setState(() => _showNewMessagePill = true);
      }
    } else {
      _renderedMessageCount = count;
    }
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
    if (_showNewMessagePill) setState(() => _showNewMessagePill = false);
  }

  Future<void> _toggleListening() async {
    final controller = _controller;
    if (controller.state == ListeningState.idle) {
      // Native engine: never start a session on an unsupported device —
      // block with the explanation dialog instead of a broken session.
      final settings = context.read<SettingsController>().settings;
      if (settings.translationEngine == TranslationEngine.onDevice &&
          !settings.mockMode) {
        final support = await sharedLiveTranslationSupport.ensure(
          targetLanguage: settings.targetLanguage,
          sourceLanguages: const ['en'], // source is automatic
        );
        if (!support.supported) {
          if (mounted) {
            await showLiveTranslationUnsupportedDialog(
              context,
              support: support,
              targetLanguage: settings.targetLanguage,
              sourceLanguages: const ['en'], // source is automatic
            );
          }
          return;
        }
      }
      await controller.startListening();
    } else if (controller.isListening) {
      await controller.stopListening();
      final summary = controller.lastSummary;
      controller.consumeSummary();
      if (mounted && summary != null) _showSummarySheet(summary);
    }
  }

  void _showSummarySheet(SessionSummary summary) {
    final minutes = summary.duration.inMinutes;
    final seconds = summary.duration.inSeconds % 60;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Translation stopped',
                  textAlign: TextAlign.center,
                  style: Theme.of(sheetContext)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(
                '${summary.translationCount} translation${summary.translationCount == 1 ? '' : 's'}'
                ' · ${minutes > 0 ? '$minutes min ' : ''}$seconds sec',
                textAlign: TextAlign.center,
                style: Theme.of(sheetContext).textTheme.bodyLarge,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  _toggleListening();
                },
                icon: const Icon(Icons.mic_rounded),
                label: const Text('Start Again'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  _confirmClear();
                },
                child: const Text('Clear Conversation'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this translation session?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) _controller.clearConversation();
  }

  @override
  void dispose() {
    _noticeSubscription?.cancel();
    _controller.removeListener(_handleControllerChanged);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LiveTranslationController>();
    final settings = context.watch<SettingsController>().settings;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Translator'),
        actions: [
          if (controller.messages.isNotEmpty && !controller.isListening)
            IconButton(
              tooltip: 'Clear Conversation',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: _confirmClear,
            ),
          IconButton(
            tooltip: 'History',
            icon: const Icon(Icons.history_rounded),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const HistoryScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (controller.errorBanner != null)
              _ErrorBanner(
                message: controller.errorBanner!,
                showOpenSettings: controller.permissionPermanentlyDenied,
                onOpenSettings: controller.openSystemSettings,
              ),
            if (controller.isListening)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: ListeningIndicator(
                  micLevel: controller.micLevel,
                  activityLabel: controller.activityLabel,
                  onStop: _toggleListening,
                ),
              ),
            Expanded(
              child: Stack(
                children: [
                  controller.messages.isEmpty
                      ? _EmptyState(
                          isListening: controller.isListening,
                          targetLanguage: settings.targetLanguage,
                        )
                      : ListView.separated(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                          itemCount: controller.messages.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final message = controller.messages[index];
                            return MessageBubble(
                              message: message,
                              showOriginal: settings.showOriginalText,
                              showTimestamp: settings.showTimestamps,
                              showLanguageLabels: settings.showLanguageLabels,
                              onReplay: () => controller.replay(message),
                              onReport: () => controller.reportBadTranslation(message),
                              onRetry: () => controller.retryTranslation(message),
                            );
                          },
                        ),
                  if (_showNewMessagePill)
                    Positioned(
                      bottom: 12,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: ActionChip(
                          avatar: const Icon(Icons.arrow_downward_rounded, size: 18),
                          label: const Text('New translation'),
                          onPressed: _scrollToBottom,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const ListenLanguageBar(),
            ListenableBuilder(
              listenable: sharedLiveTranslationSupport,
              builder: (context, _) {
                final settings = context.watch<SettingsController>().settings;
                final support = sharedLiveTranslationSupport.current;
                final blocked = settings.translationEngine ==
                        TranslationEngine.onDevice &&
                    !settings.mockMode &&
                    support != null &&
                    !support.supported;
                return _BottomControl(
                  state: controller.state,
                  onPressed: _toggleListening,
                  blocked: blocked,
                  onBlockedTap: support == null
                      ? null
                      : () => showLiveTranslationUnsupportedDialog(
                            context,
                            support: support,
                            targetLanguage: settings.targetLanguage,
                            sourceLanguages: const ['en'], // source is automatic
                          ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({
    required this.message,
    required this.showOpenSettings,
    required this.onOpenSettings,
  });

  final String message;
  final bool showOpenSettings;
  final Future<void> Function() onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onErrorContainer),
            ),
          ),
          if (showOpenSettings)
            TextButton(
              onPressed: onOpenSettings,
              child: const Text('Open Settings'),
            ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.isListening, required this.targetLanguage});

  final bool isListening;
  final String targetLanguage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final language = languageForCode(targetLanguage);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isListening ? '…' : '🎙️',
              style: const TextStyle(fontSize: 56),
            ),
            const SizedBox(height: 16),
            Text(
              isListening
                  ? 'Waiting for someone to speak…'
                  : 'Understand anyone,\nin your language.',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              isListening
                  ? 'Speech will appear here, translated automatically.'
                  : 'Languages are detected automatically.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.outline),
            ),
            if (!isListening && language != null) ...[
              const SizedBox(height: 20),
              Chip(
                avatar: Text(language.flag),
                label: Text('Your language: ${language.name}'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BottomControl extends StatelessWidget {
  const _BottomControl({
    required this.state,
    required this.onPressed,
    this.blocked = false,
    this.onBlockedTap,
  });

  final ListeningState state;
  final Future<void> Function() onPressed;

  /// Native engine on an unsupported device: the button is disabled, and a
  /// tap explains why instead of failing mysteriously.
  final bool blocked;
  final VoidCallback? onBlockedTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: switch (state) {
        ListeningState.idle => blocked
            ? GestureDetector(
                onTap: onBlockedTap,
                child: FilledButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.mic_off_rounded, size: 26),
                  label: const Text('Live Translation unavailable'),
                ),
              )
            : FilledButton.icon(
                onPressed: onPressed,
                icon: const Icon(Icons.mic_rounded, size: 26),
                label: const Text('Start Listening'),
              ),
        ListeningState.starting => FilledButton.icon(
            onPressed: null,
            icon: const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            label: const Text('Starting…'),
          ),
        ListeningState.listening => FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            onPressed: onPressed,
            icon: const Icon(Icons.stop_rounded, size: 26),
            label: const Text('Stop Listening'),
          ),
      },
    );
  }
}

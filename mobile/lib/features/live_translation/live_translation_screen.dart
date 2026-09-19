import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/billing/entitlement_controller.dart';
import '../../services/storage/settings_store.dart';
import '../subscription/paywall_screen.dart';
import '../../theme/app_colors.dart';
import '../../utils/languages.dart';
import '../../widgets/components/app_bottom_nav.dart' show bottomNavClearance;
import '../../widgets/components/app_error_banner.dart';
import '../../widgets/components/audio_waveform.dart';
import '../../widgets/components/glass_card.dart';
import '../../widgets/components/language_selector_sheet.dart';
import '../../widgets/components/listening_orb.dart';
import 'live_translation_controller.dart';
import 'widgets/message_bubble.dart';

/// Home: the live translation experience. The microphone orb is the hero;
/// the transcript grows into a conversation timeline beneath it. All session
/// behavior (start/stop, restart-on-language-change, error copy) lives in
/// [LiveTranslationController] — this screen is presentation only.
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
  bool _paywallOpen = false;

  // Resolved once: dispose() runs after this element is deactivated, when a
  // context lookup is no longer allowed.
  late final LiveTranslationController _controller =
      context.read<LiveTranslationController>();

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
  }

  bool get _isNearBottom => !_scroll.hasClients || _scroll.position.extentAfter < 120;

  void _handleControllerChanged() {
    // The server refused (or cut short) a session for lack of minutes.
    if (_controller.outOfMinutes && mounted && !_paywallOpen) {
      _controller.consumeOutOfMinutes();
      _paywallOpen = true;
      PaywallScreen.show(context).whenComplete(() => _paywallOpen = false);
    }
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
      // Cheap local check first, so an out-of-minutes user gets the paywall
      // instead of a failed connection. The SERVER still decides: it refuses
      // to mint a token without allowance, which lands in _handleOutOfMinutes.
      final entitlements = context.read<EntitlementController>();
      if (entitlements.loaded && !entitlements.canStartSession) {
        await PaywallScreen.show(context);
        return;
      }
      await controller.startListening();
    } else if (controller.isListening) {
      await controller.stopListening();
      final summary = controller.lastSummary;
      controller.consumeSummary();
      if (mounted && summary != null) _showSummarySheet(summary);
    }
    // While starting, a tap is deliberately a no-op: stopping mid-connect
    // would race the in-flight start (the controller does not cancel it)
    // and could leave the microphone on after a "stopped" summary.
  }

  void _showSummarySheet(SessionSummary summary) {
    final minutes = summary.duration.inMinutes;
    final seconds = summary.duration.inSeconds % 60;
    showModalBottomSheet<void>(
      context: context,
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
                style: Theme.of(sheetContext)
                    .textTheme
                    .bodyLarge
                    ?.copyWith(color: AppColors.textSecondary),
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
        title: const Text('Clear this conversation from the screen?'),
        content: const Text('Saved history is kept — manage it in History.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) _controller.clearConversation();
  }

  /// Privacy affordance: while the microphone is live, the status pill opens
  /// an explanation sheet with an explicit Stop.
  void _showMicActiveSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.mic_rounded, size: 44, color: AppColors.electricCyan),
              const SizedBox(height: 12),
              Text(
                'Microphone is currently active because Live Translation is running.',
                textAlign: TextAlign.center,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  _toggleListening();
                },
                icon: const Icon(Icons.stop_rounded),
                label: const Text('Stop Listening'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _noticeSubscription?.cancel();
    _controller.removeListener(_handleControllerChanged);
    _scroll.dispose();
    super.dispose();
  }

  OrbState get _orbState => switch (_controller.state) {
        ListeningState.idle => OrbState.idle,
        ListeningState.starting => OrbState.connecting,
        ListeningState.listening => OrbState.listening,
      };

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LiveTranslationController>();
    final settings = context.watch<SettingsController>().settings;
    final hasMessages = controller.messages.isNotEmpty;

    return Column(
      children: [
        // Chrome (header, selector, dock) keeps a bounded text scale so the
        // fixed blocks can't outgrow a small screen; transcript text below
        // honors the user's full text-size setting.
        MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.3,
          child: Column(
            children: [
              _Header(
                showClear: hasMessages && !controller.isListening,
                onClear: _confirmClear,
              ),
              _TargetLanguageCard(
                targetLanguage: settings.targetLanguage,
                onTap: () => showLanguageSelectorSheet(context),
              ),
            ],
          ),
        ),
        if (controller.errorBanner != null)
          AppErrorBanner(
            message: controller.errorBanner!,
            margin: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            actionLabel: controller.permissionPermanentlyDenied ? 'Open Settings' : null,
            onAction: controller.permissionPermanentlyDenied
                ? () => controller.openSystemSettings()
                : null,
          ),
        Expanded(
          child: hasMessages
              ? _TranscriptView(
                  controller: controller,
                  scroll: _scroll,
                  showNewMessagePill: _showNewMessagePill,
                  onNewMessageTap: _scrollToBottom,
                  showOriginal: settings.showOriginalText,
                  showTimestamps: settings.showTimestamps,
                  showLanguageLabels: settings.showLanguageLabels,
                )
              : _HeroIdleView(
                  state: _orbState,
                  micLevel: controller.micLevel,
                  onOrbTap: _toggleListening,
                  isListening: controller.isListening,
                  onListeningPillTap: _showMicActiveSheet,
                ),
        ),
        if (hasMessages)
          MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.3,
            child: _CompactControlDock(
              state: _orbState,
              micLevel: controller.micLevel,
              activityLabel: controller.activityLabel,
              onOrbTap: _toggleListening,
              onStatusTap: controller.isListening ? _showMicActiveSheet : null,
            ),
          ),
      ],
    );
  }
}

// ── Header ────────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.showClear, required this.onClear});

  final bool showClear;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 12, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Sayvo',
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w800)),
                Text(
                  'Speak freely. Understand instantly.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          if (showClear)
            IconButton(
              tooltip: 'Clear Conversation',
              icon: const Icon(Icons.delete_outline_rounded,
                  color: AppColors.textSecondary),
              onPressed: onClear,
            ),
        ],
      ),
    );
  }
}

// ── Target language card ─────────────────────────────────────────────────────

class _TargetLanguageCard extends StatelessWidget {
  const _TargetLanguageCard({required this.targetLanguage, required this.onTap});

  final String targetLanguage;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final language = languageForCode(targetLanguage);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Semantics(
        button: true,
        label: 'Translate to ${language?.name ?? targetLanguage}. Change target language',
        child: AppGlassCard(
          onTap: onTap,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: AppColors.primaryBlue.withValues(alpha: 0.18),
                ),
                child: const Icon(Icons.language_rounded,
                    size: 20, color: AppColors.electricCyan),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Translate to',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: AppColors.textSecondary)),
                    Row(
                      children: [
                        Text(language?.flag ?? '🌐',
                            style: const TextStyle(fontSize: 17)),
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text(
                            language?.name ?? targetLanguage,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.keyboard_arrow_down_rounded,
                  color: AppColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Hero (empty conversation) ────────────────────────────────────────────────

class _HeroIdleView extends StatelessWidget {
  const _HeroIdleView({
    required this.state,
    required this.micLevel,
    required this.onOrbTap,
    required this.isListening,
    required this.onListeningPillTap,
  });

  final OrbState state;
  final double micLevel;
  final VoidCallback onOrbTap;
  final bool isListening;
  final VoidCallback onListeningPillTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (title, subtitle) = switch (state) {
      OrbState.idle => ('Tap to start listening', 'Languages are detected automatically.'),
      OrbState.connecting => ('Connecting…', 'Securing your private translation session.'),
      OrbState.listening => ('Listening…', "Speak naturally, we'll handle the rest."),
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 420;
        final orbSize = compact ? 128.0 : 168.0;
        return SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: EdgeInsets.only(bottom: bottomNavClearance(context)),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // The waveforms share whatever width is left beside the
                  // orb and scale down on narrow phones — never overflow.
                  Row(
                    children: [
                      Expanded(
                        child: state == OrbState.listening
                            ? Center(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: AudioWaveform(level: micLevel, maxBarHeight: 22),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                      ListeningOrb(
                        state: state,
                        micLevel: micLevel,
                        onTap: onOrbTap,
                        size: orbSize,
                      ),
                      Expanded(
                        child: state == OrbState.listening
                            ? Center(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: AudioWaveform(level: micLevel, maxBarHeight: 22),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
                  SizedBox(height: compact ? 12 : 22),
                  if (isListening)
                    _ListeningPill(onTap: onListeningPillTap)
                  else
                    Text(title,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Text(
                      subtitle,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// "● Listening…" — text plus color, never color alone. Tapping opens the
/// microphone privacy sheet.
class _ListeningPill extends StatelessWidget {
  const _ListeningPill({required this.onTap, this.label = 'Listening…'});

  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: 'Microphone active. $label Tap for details and stop.',
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.glassFill,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: AppColors.glassBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.circle, size: 9, color: AppColors.danger),
              const SizedBox(width: 8),
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w800)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Transcript ───────────────────────────────────────────────────────────────

class _TranscriptView extends StatelessWidget {
  const _TranscriptView({
    required this.controller,
    required this.scroll,
    required this.showNewMessagePill,
    required this.onNewMessageTap,
    required this.showOriginal,
    required this.showTimestamps,
    required this.showLanguageLabels,
  });

  final LiveTranslationController controller;
  final ScrollController scroll;
  final bool showNewMessagePill;
  final VoidCallback onNewMessageTap;
  final bool showOriginal;
  final bool showTimestamps;
  final bool showLanguageLabels;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ListView.separated(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          itemCount: controller.messages.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final message = controller.messages[index];
            return MessageBubble(
              message: message,
              showOriginal: showOriginal,
              showTimestamp: showTimestamps,
              showLanguageLabels: showLanguageLabels,
              onReport: () => controller.reportBadTranslation(message),
              // Spoken by the device's own voice, only on an explicit tap.
              onReplay: controller.canSpeak(message)
                  ? () => controller.speakTranslation(message)
                  : null,
              isPlaying: controller.playingMessageId == message.id,
            );
          },
        ),
        if (showNewMessagePill)
          Positioned(
            bottom: 12,
            left: 0,
            right: 0,
            child: Center(
              child: ActionChip(
                avatar: const Icon(Icons.arrow_downward_rounded,
                    size: 18, color: AppColors.electricCyan),
                label: const Text('New translation'),
                onPressed: onNewMessageTap,
              ),
            ),
          ),
      ],
    );
  }
}

// ── Compact control dock (conversation in progress) ──────────────────────────

class _CompactControlDock extends StatelessWidget {
  const _CompactControlDock({
    required this.state,
    required this.micLevel,
    required this.activityLabel,
    required this.onOrbTap,
    required this.onStatusTap,
  });

  final OrbState state;
  final double micLevel;
  final String? activityLabel;
  final VoidCallback onOrbTap;
  final VoidCallback? onStatusTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final listening = state == OrbState.listening;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomNavClearance(context)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: listening
                    ? Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: AudioWaveform(level: micLevel, maxBarHeight: 16),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              ListeningOrb(
                state: state,
                micLevel: micLevel,
                onTap: onOrbTap,
                size: 84,
              ),
              Expanded(
                child: listening
                    ? Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: AudioWaveform(level: micLevel, maxBarHeight: 16),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
          if (listening && onStatusTap != null)
            _ListeningPill(onTap: onStatusTap!, label: activityLabel ?? 'Listening…')
          else if (state == OrbState.connecting)
            Text('Connecting…',
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: AppColors.textSecondary))
          else
            Text('Tap to start listening',
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../../models/translation_message.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_theme.dart';
import '../../../utils/languages.dart';

/// Speaker affordance on a finalized translation — the only way translated
/// audio is ever heard now.
class _SpeakerButton extends StatelessWidget {
  const _SpeakerButton({required this.onPressed, required this.isPlaying});

  final Future<void> Function() onPressed;
  final bool isPlaying;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: isPlaying ? 'Playing translation' : 'Play translation',
      child: InkResponse(
        onTap: () => onPressed(),
        radius: 22,
        child: Padding(
          // Keeps the tap target comfortable without enlarging the row.
          padding: const EdgeInsets.all(6),
          child: Icon(
            isPlaying ? Icons.volume_up_rounded : Icons.volume_up_outlined,
            size: 18,
            color: isPlaying ? AppColors.electricCyan : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// One translated utterance. The translation is the hero; the original is a
/// quiet second line. Both use proper bidirectional text handling — the
/// translation follows the target language's direction, the original follows
/// the source language's — instead of blindly mirroring the whole layout.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.showOriginal,
    required this.showTimestamp,
    required this.showLanguageLabels,
    this.onReplay,
    this.onReport,
    this.onRetry,
    this.isPlaying = false,
  });

  final TranslationMessage message;
  final bool showOriginal;
  final bool showTimestamp;
  final bool showLanguageLabels;

  /// Plays this translation out loud. Null when no audio was kept for it
  /// (older messages, history, or translated-audio retention turned off), and
  /// the speaker button is then hidden rather than shown doing nothing.
  final Future<void> Function()? onReplay;
  final VoidCallback? onReport;

  /// This message's translation is currently playing.
  final bool isPlaying;

  /// Resubmits a failed translation (same text, no re-recording).
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final targetRtl = isRtlLanguage(message.targetLanguage);
    final sourceRtl = isRtlLanguage(message.sourceLanguage);
    final color = speakerColor(context, message.speakerId);
    final languageLabel = detectedLanguageLabel(message.sourceLanguage, message.languageConfidence);
    final flag = detectedLanguageFlag(message.sourceLanguage, message.languageConfidence);

    return Semantics(
      label: languageLabel == null
          ? (message.speakerLabel ?? 'Speaker')
          : '${message.speakerLabel ?? 'Speaker'}, $languageLabel',
      child: GestureDetector(
        onLongPress: () => _showActions(context),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Column(
              crossAxisAlignment:
                  targetRtl ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        [
                          message.speakerLabel ?? 'Speaker',
                          // Unknown language → just "Speaker", never a
                          // "Language detected…" placeholder.
                          if (showLanguageLabels && languageLabel != null) languageLabel,
                          if (showLanguageLabels && flag != null) flag,
                        ].join(' · '),
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const Spacer(),
                    if (showTimestamp)
                      Text(
                        DateFormat.Hm().format(message.timestamp),
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: AppColors.textTertiary),
                      ),
                    // Available as soon as there is translated TEXT to read —
                    // it never waits for turnComplete or for audio.
                    if (onReplay != null) ...[
                      const SizedBox(width: 4),
                      _SpeakerButton(onPressed: onReplay!, isPlaying: isPlaying),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                // The transcript always stays visible; the translation slot
                // shows the text, a "Translating…" placeholder, or a Retry.
                switch (message.status) {
                  TranslationStatus.done => SizedBox(
                      width: double.infinity,
                      child: Text(
                        message.translatedText,
                        textDirection: targetRtl ? TextDirection.rtl : TextDirection.ltr,
                        textAlign: TextAlign.start,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          height: 1.5,
                        ),
                      ),
                    ),
                  // Streamed deltas render as they arrive — live subtitles;
                  // the spinner row only shows before the first word lands.
                  TranslationStatus.pending when message.translatedText.isNotEmpty => SizedBox(
                      width: double.infinity,
                      child: Text(
                        message.translatedText,
                        textDirection: targetRtl ? TextDirection.rtl : TextDirection.ltr,
                        textAlign: TextAlign.start,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          height: 1.45,
                        ),
                      ),
                    ),
                  TranslationStatus.pending => Row(
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.colorScheme.outline,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Translating…',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.outline,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                  TranslationStatus.failed => Row(
                      children: [
                        Icon(Icons.error_outline_rounded,
                            size: 18, color: theme.colorScheme.error),
                        const SizedBox(width: 6),
                        Text(
                          'Translation failed',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(color: theme.colorScheme.error),
                        ),
                        const SizedBox(width: 8),
                        if (onRetry != null)
                          TextButton(onPressed: onRetry, child: const Text('Retry')),
                      ],
                    ),
                },
                if (showOriginal && message.originalText.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: Text(
                      message.originalText,
                      textDirection: sourceRtl ? TextDirection.rtl : TextDirection.ltr,
                      textAlign: TextAlign.start,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppColors.textSecondary,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showActions(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Copy translation'),
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: message.translatedText));
                if (sheetContext.mounted) Navigator.pop(sheetContext);
                messenger.showSnackBar(const SnackBar(content: Text('Translation copied')));
              },
            ),
            if (message.originalText.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy_all_rounded),
                title: const Text('Copy original'),
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: message.originalText));
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                  messenger.showSnackBar(const SnackBar(content: Text('Original copied')));
                },
              ),
            if (onReplay != null)
              ListTile(
                leading: const Icon(Icons.volume_up_rounded),
                title: const Text('Play translation'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  onReplay!();
                },
              ),
            if (onReport != null)
              ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: const Text('Incorrect translation'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  onReport!();
                },
              ),
          ],
        ),
      ),
    );
  }
}

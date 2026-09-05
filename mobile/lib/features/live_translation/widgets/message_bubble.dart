import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../../models/translation_message.dart';
import '../../../theme/app_theme.dart';
import '../../../utils/languages.dart';

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
  });

  final TranslationMessage message;
  final bool showOriginal;
  final bool showTimestamp;
  final bool showLanguageLabels;
  final Future<void> Function()? onReplay;
  final VoidCallback? onReport;

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
      label: '${message.speakerLabel ?? 'Speaker'}, $languageLabel',
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
                          if (showLanguageLabels) languageLabel,
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
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
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
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    child: Text(
                      message.originalText,
                      textDirection: sourceRtl ? TextDirection.rtl : TextDirection.ltr,
                      textAlign: TextAlign.start,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.outline,
                        fontStyle: FontStyle.italic,
                        height: 1.4,
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
                title: const Text('Replay'),
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

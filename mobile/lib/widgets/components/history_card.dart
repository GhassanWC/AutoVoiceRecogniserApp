import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../services/firestore/session_repository.dart';
import '../../theme/app_colors.dart';
import '../../utils/languages.dart';
import 'glass_card.dart';

/// One saved conversation in History: target-language flag, when it happened,
/// how many translations it holds.
class HistoryCard extends StatelessWidget {
  const HistoryCard({
    super.key,
    required this.session,
    required this.onTap,
    required this.onDelete,
  });

  final SessionSummaryDoc session;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  static String friendlyDate(DateTime when) {
    final now = DateTime.now();
    final day = DateTime(when.year, when.month, when.day);
    final today = DateTime(now.year, now.month, now.day);
    final difference = today.difference(day).inDays;
    final time = DateFormat.Hm().format(when);
    if (difference == 0) return 'Today, $time';
    if (difference == 1) return 'Yesterday, $time';
    return '${DateFormat.yMMMd().format(when)}, $time';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final language = languageForCode(session.targetLanguageCode);
    final count = session.messageCount;
    return AppGlassCard(
      onTap: onTap,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: AppColors.primaryBlue.withValues(alpha: 0.16),
            ),
            child: Center(
              child: Text(language?.flag ?? '💬',
                  style: const TextStyle(fontSize: 22)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.graphic_eq_rounded,
                        size: 14, color: AppColors.electricCyan),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        'Auto → ${language?.name ?? session.targetLanguageCode}',
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    friendlyDate(session.startedAt),
                    if (count != null)
                      '$count translation${count == 1 ? '' : 's'}',
                  ].join(' · '),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Delete session',
            icon: const Icon(Icons.delete_outline_rounded,
                size: 20, color: AppColors.textTertiary),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

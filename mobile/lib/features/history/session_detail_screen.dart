import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/translation_message.dart';
import '../../services/auth/auth_controller.dart';
import '../../services/firestore/session_repository.dart';
import '../../services/storage/settings_store.dart';
import '../../theme/app_colors.dart';
import '../../utils/languages.dart';
import '../../widgets/components/app_background.dart';
import '../../widgets/components/empty_state.dart';
import '../../widgets/components/history_card.dart' show HistoryCard;
import '../live_translation/widgets/message_bubble.dart';

/// One saved conversation, rendered with the same bubbles as the live view.
class SessionDetailScreen extends StatelessWidget {
  const SessionDetailScreen({super.key, required this.session});

  final SessionSummaryDoc session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = context.watch<SettingsController>().settings;
    final uid = context.watch<AuthController>().uid;
    final sessions = context.read<SessionRepository>();
    final language = languageForCode(session.targetLanguageCode);

    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 20, 0),
                child: Row(
                  children: [
                    const BackButton(color: AppColors.textPrimary),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            HistoryCard.friendlyDate(session.startedAt),
                            style: theme.textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          if (language != null)
                            Text(
                              '${language.flag}  Translated to ${language.name}',
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: AppColors.textSecondary),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: uid == null
                    ? const SizedBox.shrink()
                    : StreamBuilder<List<TranslationMessage>>(
                        stream: sessions.watchMessages(uid, session.id),
                        builder: (context, snapshot) {
                          if (snapshot.connectionState == ConnectionState.waiting) {
                            return const Center(child: CircularProgressIndicator());
                          }
                          final messages =
                              snapshot.data ?? const <TranslationMessage>[];
                          if (messages.isEmpty) {
                            return const AppEmptyState(
                              icon: Icons.forum_outlined,
                              title: 'Nothing saved here',
                              subtitle: 'This session has no stored translations.',
                            );
                          }
                          return ListView.separated(
                            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                            itemCount: messages.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 10),
                            itemBuilder: (context, index) => MessageBubble(
                              message: messages[index],
                              showOriginal: settings.showOriginalText,
                              showTimestamp: true,
                              showLanguageLabels: settings.showLanguageLabels,
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

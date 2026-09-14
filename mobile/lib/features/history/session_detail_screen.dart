import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/translation_message.dart';
import '../../services/auth/auth_controller.dart';
import '../../services/firestore/session_repository.dart';
import '../../services/storage/settings_store.dart';
import '../live_translation/widgets/message_bubble.dart';

class SessionDetailScreen extends StatelessWidget {
  const SessionDetailScreen({super.key, required this.session});

  final SessionSummaryDoc session;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>().settings;
    final uid = context.watch<AuthController>().uid;
    final sessions = context.read<SessionRepository>();
    return Scaffold(
      appBar: AppBar(title: Text(DateFormat.yMMMd().add_Hm().format(session.startedAt))),
      body: uid == null
          ? const SizedBox.shrink()
          : StreamBuilder<List<TranslationMessage>>(
              stream: sessions.watchMessages(uid, session.id),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final messages = snapshot.data ?? const <TranslationMessage>[];
                return ListView.separated(
                  padding: const EdgeInsets.all(16),
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
    );
  }
}

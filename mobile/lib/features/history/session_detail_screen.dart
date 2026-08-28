import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/conversation_session.dart';
import '../../services/storage/settings_store.dart';
import '../live_translation/widgets/message_bubble.dart';

class SessionDetailScreen extends StatelessWidget {
  const SessionDetailScreen({super.key, required this.session});

  final ConversationSession session;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>().settings;
    return Scaffold(
      appBar: AppBar(title: Text(DateFormat.yMMMd().add_Hm().format(session.startedAt))),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: session.messages.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, index) => MessageBubble(
          message: session.messages[index],
          showOriginal: settings.showOriginalText,
          showTimestamp: true,
          showLanguageLabels: settings.showLanguageLabels,
        ),
      ),
    );
  }
}

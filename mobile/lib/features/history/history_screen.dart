import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../services/auth/auth_controller.dart';
import '../../services/firestore/session_repository.dart';
import '../../utils/languages.dart';
import 'session_detail_screen.dart';

/// Translation history from the signed-in user's private Firestore space.
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final uid = context.watch<AuthController>().uid;
    final sessions = context.read<SessionRepository>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            tooltip: 'Delete All History',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: uid == null ? null : () => _deleteAll(context, sessions, uid),
          ),
        ],
      ),
      body: uid == null
          ? const Center(child: Text('Sign in to see your history.'))
          : StreamBuilder<List<SessionSummaryDoc>>(
              stream: sessions.watchSessions(uid),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'Could not load history.\nCheck your connection and try again.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ),
                  );
                }
                final docs = snapshot.data ?? const <SessionSummaryDoc>[];
                if (docs.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'No saved conversations yet.\nFinished translations are saved here automatically.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final session = docs[index];
                    final language = languageForCode(session.targetLanguageCode);
                    final count = session.messageCount;
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 5),
                      child: ListTile(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                              builder: (_) => SessionDetailScreen(session: session)),
                        ),
                        leading:
                            Text(language?.flag ?? '💬', style: const TextStyle(fontSize: 26)),
                        title: Text(
                          DateFormat.yMMMd().add_Hm().format(session.startedAt),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text([
                          if (count != null)
                            '$count translation${count == 1 ? '' : 's'}',
                          if (language != null) '→ ${language.name}',
                        ].join(' ')),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline_rounded),
                          onPressed: () => _deleteSession(context, sessions, uid, session),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }

  Future<void> _deleteSession(BuildContext context, SessionRepository sessions, String uid,
      SessionSummaryDoc session) async {
    if (await _confirm(context, 'Delete this translation session?')) {
      await sessions.deleteSession(uid, session.id);
    }
  }

  Future<void> _deleteAll(BuildContext context, SessionRepository sessions, String uid) async {
    if (await _confirm(context, 'Delete all saved translation history?')) {
      await sessions.deleteAllSessions(uid);
    }
  }

  Future<bool> _confirm(BuildContext context, String title) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Delete')),
        ],
      ),
    );
    return result == true;
  }
}

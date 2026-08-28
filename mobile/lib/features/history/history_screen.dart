import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/conversation_session.dart';
import '../../services/storage/settings_store.dart';
import '../../services/storage/history_store.dart';
import '../../utils/languages.dart';
import 'session_detail_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final HistoryStore _store = HistoryStore();
  late Future<List<ConversationSession>> _sessions = _store.loadSessions();

  void _reload() {
    setState(() => _sessions = _store.loadSessions());
  }

  Future<void> _deleteSession(ConversationSession session) async {
    final confirmed = await _confirm('Delete this translation session?');
    if (confirmed) {
      await _store.deleteSession(session.id);
      _reload();
    }
  }

  Future<void> _deleteAll() async {
    final confirmed = await _confirm('Delete all saved translation history?');
    if (confirmed) {
      await _store.deleteAll();
      _reload();
    }
  }

  Future<bool> _confirm(String title) async {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final historyEnabled = context.watch<SettingsController>().settings.saveHistory;
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            tooltip: 'Delete All History',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _deleteAll,
          ),
        ],
      ),
      body: FutureBuilder<List<ConversationSession>>(
        future: _sessions,
        builder: (context, snapshot) {
          final sessions = snapshot.data ?? [];
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (sessions.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  historyEnabled
                      ? 'No saved conversations yet.\nSessions are saved here when they end.'
                      : 'History is off.\nEnable “Save translation history” in Settings '
                          'if you want sessions kept on this device.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.outline),
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: sessions.length,
            itemBuilder: (context, index) {
              final session = sessions[index];
              final language = languageForCode(session.targetLanguage);
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 5),
                child: ListTile(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                        builder: (_) => SessionDetailScreen(session: session)),
                  ),
                  leading: Text(language?.flag ?? '💬', style: const TextStyle(fontSize: 26)),
                  title: Text(
                    DateFormat.yMMMd().add_Hm().format(session.startedAt),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                      '${session.messages.length} translation${session.messages.length == 1 ? '' : 's'}'
                      '${language == null ? '' : ' → ${language.name}'}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () => _deleteSession(session),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../services/auth/auth_controller.dart';
import '../../services/firestore/session_repository.dart';
import '../../theme/app_colors.dart';
import '../../utils/languages.dart';
import '../../widgets/components/app_bottom_nav.dart' show bottomNavClearance;
import '../../widgets/components/empty_state.dart';
import '../../widgets/components/history_card.dart';
import 'session_detail_screen.dart';

/// Translation history from the signed-in user's private Firestore space.
/// Search is purely local: it filters the already-streamed session list by
/// target language and date text — no backend changes.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  String _query = '';

  // One Firestore listener per signed-in user, NOT one per rebuild: search
  // keystrokes call setState, and recreating the stream there would flicker
  // the list back to "loading" on every character.
  Stream<List<SessionSummaryDoc>>? _stream;
  String? _streamUid;

  Stream<List<SessionSummaryDoc>> _sessionsFor(SessionRepository sessions, String uid) {
    if (_streamUid != uid || _stream == null) {
      _streamUid = uid;
      _stream = sessions.watchSessions(uid);
    }
    return _stream!;
  }

  bool _matches(SessionSummaryDoc session) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return true;
    final language = languageForCode(session.targetLanguageCode);
    final haystack = [
      language?.name ?? '',
      language?.nativeName ?? '',
      session.targetLanguageCode,
      HistoryCard.friendlyDate(session.startedAt),
      DateFormat.yMMMMd().format(session.startedAt),
    ].join(' ').toLowerCase();
    return haystack.contains(query);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final uid = context.watch<AuthController>().uid;
    final sessions = context.read<SessionRepository>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 14, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('History',
                        style: theme.textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    Text('Your conversations, always with you.',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: AppColors.textSecondary)),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Delete All History',
                icon: const Icon(Icons.delete_sweep_outlined,
                    color: AppColors.textSecondary),
                onPressed: uid == null ? null : () => _deleteAll(context, sessions, uid),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: TextField(
            onChanged: (value) => setState(() => _query = value),
            decoration: const InputDecoration(
              // Sessions store language + date, not transcript text — the
              // hint says exactly what can be searched.
              hintText: 'Search by language or date',
              prefixIcon: Icon(Icons.search_rounded),
            ),
          ),
        ),
        Expanded(
          child: uid == null
              ? const AppEmptyState(
                  icon: Icons.lock_outline_rounded,
                  title: 'Sign in required',
                  subtitle: 'Sign in to see your saved conversations.',
                )
              : StreamBuilder<List<SessionSummaryDoc>>(
                  stream: _sessionsFor(sessions, uid),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return const AppEmptyState(
                        icon: Icons.cloud_off_rounded,
                        title: 'Could not load history',
                        subtitle: 'Check your connection and try again.',
                      );
                    }
                    final docs = snapshot.data ?? const <SessionSummaryDoc>[];
                    if (docs.isEmpty) {
                      return const AppEmptyState(
                        icon: Icons.forum_outlined,
                        title: 'No conversations yet',
                        subtitle: 'Your translated conversations will appear here.',
                      );
                    }
                    final filtered = docs.where(_matches).toList();
                    if (filtered.isEmpty) {
                      return AppEmptyState(
                        icon: Icons.search_off_rounded,
                        title: 'No matches',
                        subtitle: 'No session language or date matches "$_query".',
                      );
                    }
                    return ListView.builder(
                      padding: EdgeInsets.fromLTRB(
                          20, 10, 20, bottomNavClearance(context)),
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final session = filtered[index];
                        return HistoryCard(
                          session: session,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                                builder: (_) =>
                                    SessionDetailScreen(session: session)),
                          ),
                          onDelete: () =>
                              _deleteSession(context, sessions, uid, session),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _deleteSession(BuildContext context, SessionRepository sessions,
      String uid, SessionSummaryDoc session) async {
    if (await _confirm(context, 'Delete this translation session?')) {
      await sessions.deleteSession(uid, session.id);
    }
  }

  Future<void> _deleteAll(
      BuildContext context, SessionRepository sessions, String uid) async {
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
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete')),
        ],
      ),
    );
    return result == true;
  }
}

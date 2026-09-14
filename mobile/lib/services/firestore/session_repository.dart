import 'package:cloud_firestore/cloud_firestore.dart';

import '../../models/translation_message.dart';

/// One row in the History list (users/{uid}/sessions/{sessionId}).
class SessionSummaryDoc {
  const SessionSummaryDoc({
    required this.id,
    required this.targetLanguageCode,
    required this.startedAt,
    this.endedAt,
    this.messageCount,
  });

  final String id;
  final String targetLanguageCode;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int? messageCount;

  factory SessionSummaryDoc.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    return SessionSummaryDoc(
      id: doc.id,
      targetLanguageCode: data['targetLanguageCode'] as String? ?? 'en',
      startedAt: (data['startedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      endedAt: (data['endedAt'] as Timestamp?)?.toDate(),
      messageCount: (data['messageCount'] as num?)?.toInt(),
    );
  }
}

/// Translation history persistence. ONLY finalized messages are ever written
/// — never partial transcripts, never audio. The session document is created
/// lazily on the first finalized message so aborted starts leave no debris.
class SessionRepository {
  SessionRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> _sessions(String uid) =>
      _firestore.collection('users').doc(uid).collection('sessions');

  Future<void> createSession(
    String uid,
    String sessionId, {
    required String targetLanguageCode,
  }) =>
      _sessions(uid).doc(sessionId).set({
        'targetLanguageCode': targetLanguageCode,
        'startedAt': FieldValue.serverTimestamp(),
      });

  Future<void> endSession(String uid, String sessionId, {required int messageCount}) =>
      _sessions(uid).doc(sessionId).set({
        'endedAt': FieldValue.serverTimestamp(),
        'messageCount': messageCount,
      }, SetOptions(merge: true));

  Future<void> addMessage(
    String uid,
    String sessionId,
    TranslationMessage message,
  ) =>
      _sessions(uid).doc(sessionId).collection('messages').doc(message.id).set({
        'originalText': message.originalText,
        'translatedText': message.translatedText,
        'sourceLanguageCode': message.sourceLanguage,
        'targetLanguageCode': message.targetLanguage,
        'createdAt': FieldValue.serverTimestamp(),
        // Client timestamp keeps ordering stable while serverTimestamp is
        // still pending locally.
        'clientCreatedAt': message.timestamp.toUtc().toIso8601String(),
      });

  Stream<List<SessionSummaryDoc>> watchSessions(String uid, {int limit = 100}) => _sessions(uid)
      .orderBy('startedAt', descending: true)
      .limit(limit)
      .snapshots()
      .map((snapshot) => snapshot.docs.map(SessionSummaryDoc.fromDoc).toList());

  Stream<List<TranslationMessage>> watchMessages(String uid, String sessionId) =>
      _sessions(uid)
          .doc(sessionId)
          .collection('messages')
          .orderBy('createdAt')
          .snapshots()
          .map((snapshot) => snapshot.docs.map(_messageFromDoc).toList());

  Future<void> deleteSession(String uid, String sessionId) async {
    final sessionRef = _sessions(uid).doc(sessionId);
    while (true) {
      final messages = await sessionRef.collection('messages').limit(400).get();
      if (messages.docs.isEmpty) break;
      final batch = _firestore.batch();
      for (final message in messages.docs) {
        batch.delete(message.reference);
      }
      await batch.commit();
    }
    await sessionRef.delete();
  }

  Future<void> deleteAllSessions(String uid) async {
    final sessions = await _sessions(uid).get();
    for (final session in sessions.docs) {
      await deleteSession(uid, session.id);
    }
  }

  static TranslationMessage _messageFromDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    final created = (data['createdAt'] as Timestamp?)?.toDate() ??
        DateTime.tryParse(data['clientCreatedAt'] as String? ?? '')?.toLocal() ??
        DateTime.now();
    final source = data['sourceLanguageCode'] as String?;
    return TranslationMessage(
      id: doc.id,
      speakerId: null,
      speakerLabel: null,
      sourceLanguage: source == null || source.isEmpty ? 'und' : source,
      languageConfidence: source == null || source.isEmpty || source == 'und' ? 0 : 1,
      originalText: data['originalText'] as String? ?? '',
      translatedText: data['translatedText'] as String? ?? '',
      targetLanguage: data['targetLanguageCode'] as String? ?? 'en',
      timestamp: created,
      status: TranslationStatus.done,
    );
  }
}

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// The users/{uid} profile document.
class UserProfile {
  const UserProfile({
    required this.uid,
    this.displayName,
    this.email,
    this.photoUrl,
    this.targetLanguageCode,
  });

  final String uid;
  final String? displayName;
  final String? email;
  final String? photoUrl;
  final String? targetLanguageCode;

  factory UserProfile.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    return UserProfile(
      uid: doc.id,
      displayName: data['displayName'] as String?,
      email: data['email'] as String?,
      photoUrl: data['photoUrl'] as String?,
      targetLanguageCode: data['targetLanguageCode'] as String?,
    );
  }
}

/// users/{uid} — profile + preferences. Security rules restrict every path
/// under users/{uid} to that authenticated uid.
class UserRepository {
  UserRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  DocumentReference<Map<String, dynamic>> _userDoc(String uid) =>
      _firestore.collection('users').doc(uid);

  /// Creates/refreshes the profile document on sign-in (merge, so the
  /// target-language preference is never clobbered).
  Future<void> ensureUserDoc(User user) async {
    final existing = await _userDoc(user.uid).get();
    await _userDoc(user.uid).set({
      'displayName': user.displayName,
      'email': user.email,
      'photoUrl': user.photoURL,
      if (!existing.exists) 'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<UserProfile?> fetchProfile(String uid) async {
    final doc = await _userDoc(uid).get();
    if (!doc.exists) return null;
    return UserProfile.fromDoc(doc);
  }

  Future<void> setTargetLanguage(String uid, String code) => _userDoc(uid).set({
        'targetLanguageCode': code,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

  /// Deletes ALL of the user's data: every message, every session, then the
  /// profile document. Batched in chunks below Firestore's 500-write limit.
  Future<void> deleteAllUserData(String uid) async {
    final sessions = await _userDoc(uid).collection('sessions').get();
    for (final session in sessions.docs) {
      while (true) {
        final messages = await session.reference.collection('messages').limit(400).get();
        if (messages.docs.isEmpty) break;
        final batch = _firestore.batch();
        for (final message in messages.docs) {
          batch.delete(message.reference);
        }
        await batch.commit();
      }
      await session.reference.delete();
    }
    await _userDoc(uid).delete();
  }
}

import 'package:uuid/uuid.dart';

/// The account identifier Sayvo attaches to a store purchase.
///
/// Apple requires `appAccountToken` to be a UUID, so the Firebase uid cannot
/// be sent as-is. A UUID v5 over the uid is stable across devices and
/// reinstalls, needs no storage, and is not reversible to the uid.
///
/// The server derives the same value (functions/src/billing/account_token.ts)
/// to spot a purchase whose store-recorded account is not the caller's. Both
/// sides are pinned by a test to the same expected output.
String accountTokenForUid(String uid) =>
    const Uuid().v5(Namespace.url.value, 'sayvo:$uid');

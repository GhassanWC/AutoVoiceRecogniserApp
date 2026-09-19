import 'dart:async';
import 'dart:developer' as developer;

import 'package:cloud_functions/cloud_functions.dart';

/// Sends one tick to the backend and returns its raw reply. Injectable so the
/// meter's lifecycle can be tested without a live Firebase app.
typedef MeterSender = Future<Map<String, dynamic>> Function(
    String sessionId, bool close);

/// Reports live-translation session time to the server while listening.
///
/// The client never decides how much was used: it only says "still going",
/// and the SERVER charges the elapsed time between calls from its own clock.
/// Heartbeating every 30 s keeps a session to about two writes a minute
/// instead of one a second, while bounding how much an abandoned session can
/// cost (the server caps a single tick).
class UsageMeter {
  UsageMeter({
    FirebaseFunctions? functions,
    MeterSender? sender,
    this.interval = const Duration(seconds: 30),
  })  : _functions = functions,
        _sender = sender;

  /// Resolved lazily, and only when something is actually metered: touching
  /// FirebaseFunctions.instance eagerly would require Firebase to be
  /// initialized just to construct a controller.
  final FirebaseFunctions? _functions;
  final MeterSender? _sender;
  final Duration interval;

  Timer? _timer;
  String? _sessionId;

  /// Called when the server reports the allowance is exhausted.
  void Function()? onExhausted;

  /// Called with each fresh remainder so the UI can count down.
  void Function(double remainingMinutes)? onRemaining;

  bool get isRunning => _timer != null;

  /// Begins heartbeating for a server-issued session id.
  void start(String sessionId) {
    stopTimer();
    _sessionId = sessionId;
    _timer = Timer.periodic(interval, (_) => _beat(close: false));
  }

  /// Sends the final tick and closes the session so the last partial minute
  /// is billed and nothing keeps metering.
  Future<void> finish() async {
    stopTimer();
    final sessionId = _sessionId;
    _sessionId = null;
    if (sessionId == null) return;
    await _send(sessionId, close: true);
  }

  void stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _beat({required bool close}) async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    await _send(sessionId, close: close);
  }

  Future<void> _send(String sessionId, {required bool close}) async {
    try {
      final data = await (_sender ?? _callFunction)(sessionId, close);
      final remaining = (data['remainingMinutes'] as num?)?.toDouble() ?? 0;
      final allowed = data['allowed'] == true;
      onRemaining?.call(remaining);
      if (!allowed && !close) onExhausted?.call();
    } catch (e) {
      // A dropped heartbeat must not stop a paid session: the server bills
      // from its own clock at the next successful call, and settles the
      // session itself if the app never comes back.
      developer.log('meter heartbeat failed: $e', name: 'billing');
    }
  }

  Future<Map<String, dynamic>> _callFunction(
      String sessionId, bool close) async {
    final functions = _functions ?? FirebaseFunctions.instance;
    final response = await functions
        .httpsCallable('meterLiveTranslateSession')
        .call<Map<String, dynamic>>({'sessionId': sessionId, 'close': close});
    return Map<String, dynamic>.from(response.data);
  }

  void dispose() => stopTimer();
}

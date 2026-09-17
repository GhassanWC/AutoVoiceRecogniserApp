import 'package:flutter/foundation.dart';

/// TEMPORARY lifecycle tracing for the multi-turn ("only the first utterance
/// translates") investigation. Delete this file and its call sites — or flip
/// [kLiveDiagnostics] to false — once the issue is closed.
///
/// Uses [debugPrint], deliberately NOT `dart:developer`'s log(): developer.log
/// is routed to the VM service, which is not attached in a release/TestFlight
/// build, so those lines are invisible on a real device. debugPrint reaches the
/// iOS system log (Console.app / `idevicesyslog`) and Android logcat in release.
///
/// Privacy: never logs audio bytes, tokens, or transcript CONTENT — only
/// lengths, language codes and lifecycle facts.
const bool kLiveDiagnostics = true;

final Stopwatch _since = Stopwatch()..start();
final Map<String, int> _lastEmitMs = {};

/// One trace line: `[LT +12.34s] TAG detail`.
void liveTrace(String tag, [String detail = '']) {
  if (!kLiveDiagnostics) return;
  final seconds = (_since.elapsedMilliseconds / 1000).toStringAsFixed(2);
  debugPrint('[LT +${seconds}s] $tag${detail.isEmpty ? '' : ' $detail'}');
}

/// Like [liveTrace] but at most once per [every] for the given [tag] — for
/// high-rate events (microphone chunks arrive ~10×/second).
void liveTraceThrottled(String tag, String Function() detail,
    {Duration every = const Duration(seconds: 1)}) {
  if (!kLiveDiagnostics) return;
  final now = _since.elapsedMilliseconds;
  final last = _lastEmitMs[tag];
  if (last != null && now - last < every.inMilliseconds) return;
  _lastEmitMs[tag] = now;
  liveTrace(tag, detail());
}

/// Forgets throttle state so a new session starts with fresh logging.
void resetLiveTraceThrottles() => _lastEmitMs.clear();

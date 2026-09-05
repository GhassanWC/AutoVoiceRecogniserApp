import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../models/ws_events.dart';
import '../auth/api_client.dart';

enum LiveConnectionState { disconnected, connecting, connected, reconnecting }

/// WebSocket client for the live-translation stream.
///
/// Owns connection recovery: if the network drops while listening it retries
/// with backoff, re-opens the session, and reports state changes so the UI
/// can show "Connection lost. Trying to reconnect…". Audio captured while
/// offline is deliberately discarded — we never upload stale audio.
class LiveTranslationClient {
  LiveTranslationClient({required this.api});

  final ApiClient api;

  final StreamController<ServerEvent> _events = StreamController.broadcast();
  Stream<ServerEvent> get events => _events.stream;

  final StreamController<LiveConnectionState> _stateController = StreamController.broadcast();
  Stream<LiveConnectionState> get connectionStates => _stateController.stream;

  LiveConnectionState _state = LiveConnectionState.disconnected;
  LiveConnectionState get state => _state;
  bool get isConnected => _state == LiveConnectionState.connected;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _shouldBeConnected = false;

  String _targetLanguage = 'en';
  bool _saveHistory = false;

  /// Opens the socket and starts a listening session on the server.
  Future<void> connect({required String targetLanguage, required bool saveHistory}) async {
    _targetLanguage = targetLanguage;
    _saveHistory = saveHistory;
    _shouldBeConnected = true;
    _reconnectAttempt = 0;
    await _open();
  }

  Future<void> _open() async {
    _setState(
      _reconnectAttempt == 0 ? LiveConnectionState.connecting : LiveConnectionState.reconnecting,
    );
    try {
      final token = await api.getAuthToken(preferredLanguage: _targetLanguage);
      final uri = Uri.parse('${api.webSocketUrl}?token=${Uri.encodeComponent(token)}');
      final channel = WebSocketChannel.connect(uri);
      await channel.ready.timeout(const Duration(seconds: 10));
      if (!_shouldBeConnected) {
        await channel.sink.close();
        return;
      }
      _channel = channel;
      _subscription = channel.stream.listen(
        _handleData,
        onDone: () => _handleClosed(channel.closeCode),
        onError: (Object _) => _handleClosed(null),
        cancelOnError: true,
      );
      _sendJson({
        'type': 'session_start',
        'targetLanguage': _targetLanguage,
        'saveHistory': _saveHistory,
      });
      _setState(LiveConnectionState.connected);
      _reconnectAttempt = 0;
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(const Duration(seconds: 25), (_) {
        _sendJson({'type': 'ping', 't': DateTime.now().millisecondsSinceEpoch});
      });
    } catch (_) {
      unawaited(_handleClosed(null));
    }
  }

  void _handleData(dynamic data) {
    if (data is String) {
      final event = ServerEvent.parse(data);
      if (event != null) _events.add(event);
    }
  }

  Future<void> _handleClosed(int? closeCode) async {
    _heartbeat?.cancel();
    _heartbeat = null;
    await _subscription?.cancel();
    _subscription = null;
    _channel = null;

    if (closeCode == 4401) {
      // Expired/invalid token — a fresh guest token fixes it on retry.
      await api.clearAuthToken();
    }

    if (!_shouldBeConnected) {
      _setState(LiveConnectionState.disconnected);
      return;
    }
    _setState(LiveConnectionState.reconnecting);
    _reconnectAttempt++;
    final delaySeconds = math.min(15, math.pow(2, math.min(_reconnectAttempt, 4)).toInt());
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      if (_shouldBeConnected) _open();
    });
  }

  void sendSegmentStart(String segmentId, int sampleRate) {
    _sendJson({
      'type': 'segment_start',
      'segmentId': segmentId,
      'sampleRate': sampleRate,
      'channels': 1,
      'encoding': 'pcm16',
    });
  }

  void sendAudio(String segmentId, int sequence, Uint8List pcm) {
    final channel = _channel;
    if (channel == null || !isConnected) return;
    channel.sink.add(encodeAudioFrame(segmentId, sequence, pcm));
  }

  void sendSegmentEnd(String segmentId, int durationMs) {
    _sendJson({'type': 'segment_end', 'segmentId': segmentId, 'durationMs': durationMs});
  }

  void sendSessionStop() {
    _sendJson({'type': 'session_stop'});
  }

  /// Ask the server to re-translate an existing transcript (no new audio).
  void sendRetryTranslation(String messageId) {
    _sendJson({'type': 'retry_translation', 'messageId': messageId});
  }

  void _sendJson(Map<String, dynamic> message) {
    final channel = _channel;
    if (channel == null) return;
    channel.sink.add(jsonEncode(message));
  }

  /// Graceful shutdown: no reconnect attempts, socket closed.
  Future<void> disconnect() async {
    _shouldBeConnected = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
    _setState(LiveConnectionState.disconnected);
  }

  void _setState(LiveConnectionState next) {
    if (_state == next) return;
    _state = next;
    _stateController.add(next);
  }

  void dispose() {
    disconnect();
    _events.close();
    _stateController.close();
  }
}

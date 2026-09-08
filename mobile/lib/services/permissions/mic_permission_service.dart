import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

enum MicPermissionStatus { granted, denied, permanentlyDenied, unsupported }

/// Wraps OS microphone permission. Note the product rule this enforces by
/// design: holding the OS permission never starts listening by itself — only
/// the explicit Start Listening button does.
///
/// On iOS the OS state is read/requested through OUR native channel
/// (AVAudioSession in AppDelegate.swift) — never through a plugin helper.
/// permission_handler_apple compiles microphone support out unless the
/// Podfile defines PERMISSION_MICROPHONE=1, and a build without that macro
/// reports "denied" forever while iOS Settings shows the permission granted.
/// Native iOS saying "granted" is final; no plugin opinion may veto it.
class MicPermissionService {
  static const MethodChannel _native = MethodChannel('app.livetranslator/audio');

  Future<MicPermissionStatus> currentStatus() async {
    if (kIsWeb) return MicPermissionStatus.unsupported;
    if (Platform.isIOS) {
      final native = await _nativeStatus();
      if (native != null) return native;
    }
    try {
      final status = await Permission.microphone.status;
      return _map(status);
    } catch (_) {
      return MicPermissionStatus.unsupported;
    }
  }

  /// Requests the OS permission dialog (or returns the settled state).
  /// iOS goes through the native channel so the request can never fire twice
  /// through competing libraries.
  Future<MicPermissionStatus> request() async {
    if (kIsWeb) return MicPermissionStatus.unsupported;
    if (Platform.isIOS) {
      try {
        final granted = await _native.invokeMethod<bool>('micRequest');
        if (granted == true) return MicPermissionStatus.granted;
        // iOS never re-shows the dialog after a denial — only the Settings
        // app can flip it back, so a denial here is always "permanent".
        return MicPermissionStatus.permanentlyDenied;
      } catch (_) {
        // Old native binary without micRequest — fall through to the plugin.
      }
    }
    try {
      final status = await Permission.microphone.request();
      return _map(status);
    } catch (_) {
      return MicPermissionStatus.unsupported;
    }
  }

  /// For the "Open Settings" button after a permanent denial. We never loop
  /// permission prompts at the user.
  Future<void> openSystemSettings() => openAppSettings();

  /// The raw native answer ("granted" / "denied" / "undetermined"), or null
  /// where the channel is unavailable (Android, web, tests).
  Future<MicPermissionStatus?> _nativeStatus() async {
    try {
      final status = await _native.invokeMethod<String>('micStatus');
      switch (status) {
        case 'granted':
          return MicPermissionStatus.granted;
        case 'undetermined':
          // Genuinely never asked → map to denied so the caller runs the one
          // legitimate request() and iOS shows its dialog.
          return MicPermissionStatus.denied;
        case 'denied':
          return MicPermissionStatus.permanentlyDenied;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  MicPermissionStatus _map(PermissionStatus status) {
    if (status.isGranted || status.isLimited) return MicPermissionStatus.granted;
    if (status.isPermanentlyDenied) return MicPermissionStatus.permanentlyDenied;
    return MicPermissionStatus.denied;
  }
}

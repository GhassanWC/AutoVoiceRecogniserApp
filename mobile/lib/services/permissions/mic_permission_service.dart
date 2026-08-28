import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

enum MicPermissionStatus { granted, denied, permanentlyDenied, unsupported }

/// Wraps OS microphone permission. Note the product rule this enforces by
/// design: holding the OS permission never starts listening by itself — only
/// the explicit Start Listening button does.
class MicPermissionService {
  Future<MicPermissionStatus> currentStatus() async {
    if (kIsWeb) return MicPermissionStatus.unsupported;
    try {
      final status = await Permission.microphone.status;
      return _map(status);
    } catch (_) {
      return MicPermissionStatus.unsupported;
    }
  }

  /// Requests the OS permission dialog (or returns the settled state).
  Future<MicPermissionStatus> request() async {
    if (kIsWeb) return MicPermissionStatus.unsupported;
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

  MicPermissionStatus _map(PermissionStatus status) {
    if (status.isGranted || status.isLimited) return MicPermissionStatus.granted;
    if (status.isPermanentlyDenied) return MicPermissionStatus.permanentlyDenied;
    return MicPermissionStatus.denied;
  }
}

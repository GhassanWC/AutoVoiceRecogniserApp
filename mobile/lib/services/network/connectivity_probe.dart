import 'dart:async';
import 'dart:io';

/// Whether the device can currently reach the internet, checked by resolving
/// the Gemini API host. Used ONLY to decide between "you are offline" copy
/// and surfacing the real failure — never as a pre-flight gate.
Future<bool> hasInternetConnection(
    {Duration timeout = const Duration(seconds: 4)}) async {
  try {
    final addresses = await InternetAddress.lookup('generativelanguage.googleapis.com')
        .timeout(timeout);
    return addresses.isNotEmpty && addresses.first.rawAddress.isNotEmpty;
  } on SocketException {
    return false;
  } on TimeoutException {
    return false;
  }
}

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// One-shot cleanup of the removed whisper.cpp engine's ggml downloads —
/// up to ~574 MB of dead weight under Application Support/offline_models
/// with no remaining in-app way to delete it. Safe to remove: the directory
/// only ever held re-downloadable model weights (and the load-attempt
/// sentinel), never user data.
Future<void> deleteLegacyGgmlModels() async {
  if (kIsWeb) return;
  try {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}offline_models');
    if (await dir.exists()) await dir.delete(recursive: true);
  } catch (_) {
    // Best-effort: a locked file just means the cleanup retries next launch.
  }
}

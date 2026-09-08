import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'local_speech_engine.dart';
import 'offline_model_manager.dart';

/// ggml files start with magic 0x67676d6c ("ggml"), stored little-endian on
/// disk as the bytes 6C 6D 67 67. An HTML/JSON error page saved by a broken
/// download starts with '<' or '{' instead.
const List<int> kGgmlMagicBytes = [0x6c, 0x6d, 0x67, 0x67];

class ModelLoadReport {
  const ModelLoadReport({required this.passed, required this.details});
  final bool passed;

  /// Full multi-line diagnostic text (also emitted to the developer log).
  final String details;
}

/// Classifies the first bytes of a downloaded model file.
String describeHeader(List<int> header) {
  if (header.length < 4) return 'too short (${header.length} bytes)';
  final hex = header
      .take(4)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join(' ');
  final isGgml = header[0] == kGgmlMagicBytes[0] &&
      header[1] == kGgmlMagicBytes[1] &&
      header[2] == kGgmlMagicBytes[2] &&
      header[3] == kGgmlMagicBytes[3];
  if (isGgml) return 'ggml magic OK ($hex)';
  if (header[0] == 0x3c) return 'HTML DOCUMENT — an error page was saved, not a model ($hex)';
  if (header[0] == 0x7b) return 'JSON — an API error response was saved, not a model ($hex)';
  return 'UNKNOWN magic ($hex) — not a ggml Whisper model';
}

class PreloadCheckResult {
  const PreloadCheckResult({required this.ok, required this.lines, required this.modelPath});
  final bool ok;
  final List<String> lines;
  final String modelPath;

  /// One-line summary of what failed (empty when ok).
  String get failureSummary => ok
      ? ''
      : lines
          .where((l) =>
              l.startsWith('exists=false') ||
              l.contains('READ FAILED') ||
              l.startsWith('sha256Valid=false') ||
              l.contains('not a') ||
              l.contains('error page'))
          .join('; ');
}

/// The [WHISPER LOAD] precheck block, run IMMEDIATELY before every native
/// load (Start Listening and the Test button alike): existence, exact size,
/// fresh SHA-256, readability and ggml magic bytes — so an HTML error page
/// or truncated download can never reach the native loader unnoticed.
/// The model stays in place in Application Support; nothing moves/deletes it.
Future<PreloadCheckResult> whisperPreloadChecks({
  required OfflineModelSpec spec,
  required OfflineModelManager manager,
}) async {
  final lines = <String>[];
  void log(String line) {
    lines.add(line);
    developer.log(line, name: 'whisper');
  }

  final modelPath = await manager.pathFor(spec);
  final file = File(modelPath);
  final exists = await file.exists();
  final fileSize = exists ? await file.length() : -1;

  String headerInfo = 'unreadable';
  var readable = false;
  if (exists) {
    try {
      final raf = await file.open();
      final header = await raf.read(8);
      await raf.close();
      readable = true;
      headerInfo = describeHeader(header);
    } catch (error) {
      headerInfo = 'READ FAILED: $error';
    }
  }

  // SHA-256 re-verified right before load (hashes the whole file — a few
  // seconds for the 547 MB model, worth it while we debug this path).
  var sha256Valid = false;
  if (exists && fileSize == spec.sizeBytes) {
    sha256Valid = await verifyFile(modelPath, spec.sizeBytes, spec.sha256);
  }

  log('[WHISPER LOAD]');
  log('modelPath=$modelPath');
  log('exists=$exists');
  log('fileSize=$fileSize');
  log('expectedSize=${spec.sizeBytes}');
  log('sha256Valid=$sha256Valid');
  log('filename=${spec.fileName}');
  log('readable=$readable');
  log('header=$headerInfo');

  final ok = exists &&
      fileSize == spec.sizeBytes &&
      sha256Valid &&
      readable &&
      headerInfo.startsWith('ggml magic OK');
  if (!ok) {
    log('[WHISPER LOAD ERROR]');
    log('type=FilesystemPrecheckFailure');
    log('message=model file failed pre-load verification (see fields above); '
        'delete and re-download it');
  }
  return PreloadCheckResult(ok: ok, lines: lines, modelPath: modelPath);
}

// ── Native-crash evidence ────────────────────────────────────────────────────
// A native SIGABRT/SIGSEGV (or a jetsam memory kill) inside the whisper loader
// takes the whole process down before any Dart catch runs. So a sentinel file
// is written IMMEDIATELY before each native FFI call and deleted right after:
// if the sentinel still exists on the next run, the previous attempt provably
// died inside native code, and the phase says which call was in flight.

const String kLoadSentinelFileName = 'whisper_load_attempt.json';

Future<File> _sentinelFile(OfflineModelManager manager, OfflineModelSpec spec) async {
  final modelPath = await manager.pathFor(spec);
  return File(
      '${File(modelPath).parent.path}${Platform.pathSeparator}$kLoadSentinelFileName');
}

/// Marks that a native whisper call is about to run ([phase] names it).
Future<void> markNativeLoadAttempt({
  required OfflineModelManager manager,
  required OfflineModelSpec spec,
  required String phase,
}) async {
  final file = await _sentinelFile(manager, spec);
  await file.writeAsString(jsonEncode({
    'phase': phase,
    'model': spec.key,
    'startedAt': DateTime.now().toIso8601String(),
  }), flush: true);
}

/// Clears the sentinel — the native call returned (success or caught error).
Future<void> clearNativeLoadAttempt({
  required OfflineModelManager manager,
  required OfflineModelSpec spec,
}) async {
  final file = await _sentinelFile(manager, spec);
  if (await file.exists()) await file.delete();
}

/// If a previous attempt died natively, returns the evidence lines (and
/// clears the sentinel so the report doesn't repeat forever); null otherwise.
Future<List<String>?> takeNativeCrashEvidence({
  required OfflineModelManager manager,
  required OfflineModelSpec spec,
}) async {
  final file = await _sentinelFile(manager, spec);
  if (!await file.exists()) return null;
  String phase = 'unknown', model = 'unknown', startedAt = 'unknown';
  try {
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    phase = '${data['phase'] ?? phase}';
    model = '${data['model'] ?? model}';
    startedAt = '${data['startedAt'] ?? startedAt}';
  } catch (_) {
    // Corrupt sentinel still proves a crash happened; report it as unknown.
  }
  await file.delete().catchError((_) => file);
  return [
    '[WHISPER NATIVE CRASH EVIDENCE]',
    'A previous model-load attempt DID NOT COMPLETE: the process died inside',
    'native code (SIGABRT/SIGSEGV or an out-of-memory kill) — no Dart',
    'exception can report this, which is why the app just vanished.',
    'crashedPhase=$phase',
    'crashedModel=$model',
    'crashedAt=$startedAt',
    'Get the native stack: iPhone Settings → Privacy & Security → Analytics &',
    'Improvements → Analytics Data → newest "Runner" / "live_translator" item,',
    'or App Store Connect → TestFlight → Crashes. The crashing function/library',
    'in that report is the ground truth.',
  ];
}

/// Loads the selected offline model WITHOUT touching the microphone and
/// reports either "Model load: PASS" or the exact filesystem/native failure.
/// Used by the Settings "Test Offline Model" button and by the live
/// controller's failure path, so the generic UI message is never the only
/// evidence.
Future<ModelLoadReport> runModelLoadTest({
  required OfflineModelSpec spec,
  required OfflineModelManager manager,
  required LocalSpeechEngine Function() engineFactory,
  String Function()? nativeVersion,
  String Function()? nativeSystemInfo,
}) async {
  final lines = <String>[];
  void log(String line) {
    lines.add(line);
    developer.log(line, name: 'whisper');
  }

  // Evidence of a previous attempt that killed the process natively — shown
  // FIRST, because it explains why no Dart error was ever seen.
  final crashEvidence = await takeNativeCrashEvidence(manager: manager, spec: spec);
  crashEvidence?.forEach(log);

  final precheck = await whisperPreloadChecks(spec: spec, manager: manager);
  precheck.lines.forEach(lines.add);

  final filesystemOk = precheck.ok;
  final modelPath = precheck.modelPath;

  // Native library identification — if even these throw, the bundled
  // whisper.cpp binary itself is the problem, not the model file.
  try {
    await markNativeLoadAttempt(
        manager: manager, spec: spec, phase: 'native_library_probe');
    log('WhisperEngine.version=${nativeVersion?.call() ?? WhisperLocalSpeechEngine.nativeVersion}');
    log('WhisperEngine.systemInfo=${nativeSystemInfo?.call() ?? WhisperLocalSpeechEngine.nativeSystemInfo}');
    await clearNativeLoadAttempt(manager: manager, spec: spec);
  } catch (error, stack) {
    await clearNativeLoadAttempt(manager: manager, spec: spec);
    log('[WHISPER LOAD ERROR]');
    log('type=${error.runtimeType} (native library unavailable)');
    log('message=$error');
    log('stack=${_firstLines(stack, 8)}');
    return ModelLoadReport(passed: false, details: lines.join('\n'));
  }

  if (!filesystemOk) {
    return ModelLoadReport(passed: false, details: lines.join('\n'));
  }

  final engine = engineFactory();
  try {
    final started = DateTime.now();
    await markNativeLoadAttempt(
        manager: manager, spec: spec, phase: 'native_model_load');
    await engine.load(modelPath);
    await clearNativeLoadAttempt(manager: manager, spec: spec);
    final ms = DateTime.now().difference(started).inMilliseconds;
    log('Model load: PASS (${ms}ms, ${spec.displayName})');
    return ModelLoadReport(passed: true, details: lines.join('\n'));
  } catch (error, stack) {
    await clearNativeLoadAttempt(manager: manager, spec: spec);
    log('[WHISPER LOAD ERROR]');
    log('type=${error.runtimeType}');
    log('message=$error');
    log('nativeDetails=${_nativeDetails(error)}');
    log('stack=${_firstLines(stack, 12)}');
    if (spec.key != 'small-q5_1') {
      log('hint=retry with the small-q5_1 baseline model '
          '(Settings → Developer → Offline Whisper Model)');
    }
    return ModelLoadReport(passed: false, details: lines.join('\n'));
  } finally {
    await engine.dispose().catchError((_) {});
  }
}

String _nativeDetails(Object error) {
  // WhisperException carries the native failure text in its message.
  try {
    final dynamic raw = error;
    // ignore: avoid_dynamic_calls
    return raw.message as String;
  } catch (_) {
    return error.toString();
  }
}

String _firstLines(StackTrace stack, int count) =>
    stack.toString().split('\n').take(count).join(' | ');

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// One downloadable offline AI model (ggml Whisper weights today; the local
/// translation model joins this catalog in Phase B).
class OfflineModelSpec {
  const OfflineModelSpec({
    required this.key,
    required this.displayName,
    required this.fileName,
    required this.url,
    required this.sizeBytes,
    required this.sha256,
    required this.notes,
  });

  final String key;
  final String displayName;
  final String fileName;
  final String url;
  final int sizeBytes;

  /// Expected SHA-256 of the downloaded file — verified before first use.
  final String sha256;
  final String notes;

  String get sizeLabel => '${(sizeBytes / (1024 * 1024)).toStringAsFixed(0)} MB';
}

/// Multilingual-only catalog (never .en models — the product listens to
/// Arabic/Thai/Bengali/Hindi/… interchangeably). Checksums pinned from
/// huggingface.co/ggerganov/whisper.cpp.
const List<OfflineModelSpec> kOfflineModelCatalog = [
  OfflineModelSpec(
    key: 'large-v3-turbo-q5_0',
    displayName: 'Whisper Large v3 Turbo (quantized)',
    fileName: 'ggml-large-v3-turbo-q5_0.bin',
    url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin',
    sizeBytes: 574041195,
    sha256: '394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2',
    notes: 'Best multilingual accuracy. Heavier on battery/thermals.',
  ),
  OfflineModelSpec(
    key: 'small-q5_1',
    displayName: 'Whisper Small (quantized)',
    fileName: 'ggml-small-q5_1.bin',
    url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin',
    sizeBytes: 190085487,
    sha256: 'ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb',
    notes: 'Multilingual, ~3× smaller — use if the phone runs hot with Turbo.',
  ),
];

OfflineModelSpec offlineModelForKey(String key) => kOfflineModelCatalog.firstWhere(
      (spec) => spec.key == key,
      orElse: () => kOfflineModelCatalog.first,
    );

enum OfflineModelState { notDownloaded, downloading, verifying, ready, failed }

/// One app-wide instance so the live controller and the Settings download UI
/// observe the same state.
final OfflineModelManager sharedOfflineModels = OfflineModelManager();

/// Downloads, verifies and stores the offline AI models.
///
/// Models are fetched ONCE on demand (the App Store binary stays small),
/// stored under the iOS Application Support directory (backed-up-excluded
/// app storage, not user Documents), verified against a pinned SHA-256, and
/// deletable/re-downloadable from Settings. Raw audio is unrelated to this
/// storage — only model weights live here.
class OfflineModelManager extends ChangeNotifier {
  OfflineModelManager({Directory? overrideDirectory, http.Client? client})
      : _overrideDirectory = overrideDirectory,
        _client = client ?? http.Client();

  final Directory? _overrideDirectory;
  final http.Client _client;

  OfflineModelState state = OfflineModelState.notDownloaded;

  /// 0..1 while downloading.
  double progress = 0;
  String? errorMessage;
  int storageUsedBytes = 0;

  Future<Directory> _modelsDirectory() async {
    final base = _overrideDirectory ?? await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}offline_models');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String> pathFor(OfflineModelSpec spec) async {
    final dir = await _modelsDirectory();
    return '${dir.path}${Platform.pathSeparator}${spec.fileName}';
  }

  /// Refreshes [state]/[storageUsedBytes] for the given model.
  Future<bool> isReady(OfflineModelSpec spec) async {
    final file = File(await pathFor(spec));
    final exists = await file.exists() && await file.length() == spec.sizeBytes;
    if (state != OfflineModelState.downloading && state != OfflineModelState.verifying) {
      state = exists ? OfflineModelState.ready : OfflineModelState.notDownloaded;
    }
    await _refreshStorageUsed();
    notifyListeners();
    return exists;
  }

  Future<void> _refreshStorageUsed() async {
    var total = 0;
    final dir = await _modelsDirectory();
    await for (final entity in dir.list()) {
      if (entity is File) total += await entity.length();
    }
    storageUsedBytes = total;
  }

  /// Streams the model to disk with progress, then verifies the checksum.
  Future<bool> download(OfflineModelSpec spec) async {
    if (state == OfflineModelState.downloading) return false;
    state = OfflineModelState.downloading;
    progress = 0;
    errorMessage = null;
    notifyListeners();

    final targetPath = await pathFor(spec);
    final partFile = File('$targetPath.part');
    try {
      final request = http.Request('GET', Uri.parse(spec.url))..followRedirects = true;
      final response = await _client.send(request);
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode} downloading model');
      }
      final sink = partFile.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          final next = received / spec.sizeBytes;
          if (next - progress >= 0.01) {
            progress = next.clamp(0.0, 1.0);
            notifyListeners();
          }
        }
      } finally {
        await sink.close();
      }

      state = OfflineModelState.verifying;
      notifyListeners();
      final ok = await verifyFile(partFile.path, spec.sizeBytes, spec.sha256);
      if (!ok) {
        await partFile.delete();
        throw const FormatException('Model checksum verification failed');
      }
      await partFile.rename(targetPath);
      state = OfflineModelState.ready;
      progress = 1;
      await _refreshStorageUsed();
      notifyListeners();
      return true;
    } catch (error) {
      if (await partFile.exists()) await partFile.delete().catchError((_) => partFile);
      state = OfflineModelState.failed;
      errorMessage = error is FormatException
          ? 'Downloaded file failed verification. Please try again.'
          : 'Download failed. Check your connection and retry.';
      notifyListeners();
      return false;
    }
  }

  Future<void> delete(OfflineModelSpec spec) async {
    final file = File(await pathFor(spec));
    if (await file.exists()) await file.delete();
    state = OfflineModelState.notDownloaded;
    progress = 0;
    await _refreshStorageUsed();
    notifyListeners();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}

/// Pure verification helper (unit-tested): exact size + SHA-256 match.
Future<bool> verifyFile(String path, int expectedBytes, String expectedSha256) async {
  final file = File(path);
  if (!await file.exists()) return false;
  if (await file.length() != expectedBytes) return false;
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString().toLowerCase() == expectedSha256.toLowerCase();
}

/// Human-readable bytes for the Settings storage row.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 MB';
  const mb = 1024 * 1024;
  if (bytes >= mb * 1024) return '${(bytes / (mb * 1024)).toStringAsFixed(2)} GB';
  return '${(bytes / mb).toStringAsFixed(0)} MB';
}

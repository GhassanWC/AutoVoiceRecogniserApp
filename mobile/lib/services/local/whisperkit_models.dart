/// WhisperKit Core ML model catalog (Phase A on-device speech).
///
/// DIAGNOSTIC BUILD: exactly ONE model, and it is BUNDLED INSIDE THE APP at
/// CI time (ios/Runner/WhisperModels — see codemagic.yaml). Nothing is ever
/// downloaded at runtime: WhisperKit's runtime downloader hung indefinitely
/// on real iPhones, so it is disabled (download:false in the Swift bridge).
/// Multilingual variant only (never .en): the product listens to
/// Arabic/Thai/Bengali/Hindi/… interchangeably.
class WhisperKitModelSpec {
  const WhisperKitModelSpec({
    required this.key,
    required this.displayName,
    required this.variant,
    required this.sizeLabel,
    required this.notes,
  });

  /// Stable settings key (any stored key resolves to the bundled model via
  /// [whisperKitModelForKey]'s fallback, so old choices never break).
  final String key;
  final String displayName;

  /// WhisperKit variant name — also the bundled folder name inside
  /// <app bundle>/WhisperModels/.
  final String variant;
  final String sizeLabel;
  final String notes;
}

const List<WhisperKitModelSpec> kWhisperKitModelCatalog = [
  WhisperKitModelSpec(
    key: 'small-q5_1',
    displayName: 'Whisper Small (bundled)',
    variant: 'openai_whisper-small',
    sizeLabel: '~500 MB',
    notes: 'Ships inside the app — works fully offline, nothing to download.',
  ),
];

WhisperKitModelSpec whisperKitModelForKey(String key) =>
    kWhisperKitModelCatalog.firstWhere(
      (spec) => spec.key == key,
      orElse: () => kWhisperKitModelCatalog.first,
    );

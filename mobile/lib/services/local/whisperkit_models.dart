/// WhisperKit Core ML model catalog (Phase A on-device speech).
///
/// Models live in huggingface.co/argmaxinc/whisperkit-coreml and are
/// downloaded + cached by WhisperKit itself on first load — no manual
/// download manager, no checksums to keep here. Multilingual variants ONLY
/// (never .en): the product listens to Arabic/Thai/Bengali/Hindi/…
/// interchangeably.
class WhisperKitModelSpec {
  const WhisperKitModelSpec({
    required this.key,
    required this.displayName,
    required this.variant,
    required this.sizeLabel,
    required this.notes,
  });

  /// Stable settings key. Kept IDENTICAL to the old ggml catalog keys so a
  /// stored model choice survives the whisper.cpp → WhisperKit migration.
  final String key;
  final String displayName;

  /// WhisperKit variant name inside argmaxinc/whisperkit-coreml.
  final String variant;
  final String sizeLabel;
  final String notes;
}

const List<WhisperKitModelSpec> kWhisperKitModelCatalog = [
  WhisperKitModelSpec(
    key: 'large-v3-turbo-q5_0',
    displayName: 'Whisper Large v3 Turbo (compressed)',
    variant: 'openai_whisper-large-v3-v20240930_626MB',
    sizeLabel: '~626 MB',
    notes: 'Best multilingual accuracy. One-time download on first use.',
  ),
  WhisperKitModelSpec(
    key: 'small-q5_1',
    displayName: 'Whisper Small',
    variant: 'openai_whisper-small',
    sizeLabel: '~500 MB',
    notes: 'Lighter and cooler — use if the phone struggles with Turbo.',
  ),
];

WhisperKitModelSpec whisperKitModelForKey(String key) =>
    kWhisperKitModelCatalog.firstWhere(
      (spec) => spec.key == key,
      orElse: () => kWhisperKitModelCatalog.first,
    );

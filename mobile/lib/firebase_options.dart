// PLACEHOLDER — replace by running the FlutterFire CLI:
//
//   cd mobile
//   flutterfire configure
//
// That generates the real DefaultFirebaseOptions for the registered iOS app
// (com.ghassanalhattali.livetranslator) and Android app
// (com.livetranslator.live_translator), plus GoogleService-Info.plist and
// google-services.json. Until then the app fails fast with this message.

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    throw UnsupportedError(
      'Firebase is not configured yet. Run `flutterfire configure` in the '
      'mobile/ directory to generate lib/firebase_options.dart for this '
      'project (see README.md).',
    );
  }
}

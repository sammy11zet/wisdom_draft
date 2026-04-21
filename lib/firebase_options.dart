import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Replace the placeholder values below with the Firebase config values
/// from your Firebase project settings.
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return ios;
      default:
        throw UnsupportedError('DefaultFirebaseOptions are not supported for this platform.');
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyDzsNJIhurRV1fqPUqEW6nBa0Uvb-yj6Bc',
    authDomain: 'wisdom-draft.firebaseapp.com',
    projectId: 'wisdom-draft',
    storageBucket: 'wisdom-draft.firebasestorage.app',
    messagingSenderId: '160007639419',
    appId: '1:160007639419:web:c9c0416c4852368ddaadde',
    measurementId: 'G-CLVJ48S76J',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyDjQI5DPcT6Q-f-3uHIv7_JdNDaLD88Byk',
    appId: '1:160007639419:android:f72de5576ae8487fdaadde',
    messagingSenderId: '160007639419',
    projectId: 'wisdom-draft',
    storageBucket: 'wisdom-draft.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyCr4zoue1MaRcuO83WYWCmUSrgrg-NU5Zc',
    appId: '1:160007639419:ios:9b6fd61466237853daadde',
    messagingSenderId: '160007639419',
    projectId: 'wisdom-draft',
    storageBucket: 'wisdom-draft.firebasestorage.app',
    iosBundleId: 'winsdomdraft',
  );
}

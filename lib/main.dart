import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'firebase_options.dart';
import 'screens/home_screen.dart';

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Hive uses IndexedDB on web; iOS Safari private mode can restrict it.
    // Wrap in try-catch so the game still starts even if storage fails.
    try {
      await Hive.initFlutter();
      await Hive.openBox('leaderboard');
    } catch (_) {
      // Continue without local storage — game is still fully playable.
    }

    try {
      final firebaseOptions = DefaultFirebaseOptions.currentPlatform;
      if (firebaseOptions.apiKey != 'YOUR_API_KEY') {
        await Firebase.initializeApp(options: firebaseOptions);
      }
    } catch (_) {}

    runApp(const WisdomDraftApp());
  }, (error, stack) {
    debugPrint('Unhandled Dart error: $error\n$stack');
  });
}

class WisdomDraftApp extends StatelessWidget {
  const WisdomDraftApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wisdom Draft: GES Art Studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFCE1126), // Ghana Red
          primary: const Color(0xFFCE1126),
          secondary: const Color(0xFF006B3F), // Ghana Green
          tertiary: const Color(0xFFFCD116), // Ghana Gold
          surface: const Color(0xFF1E1E1E), // Dark charcoal background
        ),
        scaffoldBackgroundColor: const Color(0xFF1E1E1E),
        textTheme: GoogleFonts.philosopherTextTheme(),
      ),
      home: const HomeScreen(),
    );
  }
}

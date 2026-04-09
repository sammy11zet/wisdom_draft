import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await Hive.openBox('leaderboard');

  runApp(const WisdomDraftApp());
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

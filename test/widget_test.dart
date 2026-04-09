// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:wisdom_draft/main.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final tempDir = await Directory.systemTemp.createTemp('wisdom_draft_test');
    Hive.init(tempDir.path);
    await Hive.openBox('leaderboard');
  });

  testWidgets('App loads and shows player turn', (WidgetTester tester) async {
    await tester.pumpWidget(const WisdomDraftApp());
    await tester.pumpAndSettle();

    expect(find.text('PLAYER TURN'), findsOneWidget);
    expect(find.text('WISDOM DRAFT'), findsOneWidget);
  });
}

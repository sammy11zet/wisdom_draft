import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive/hive.dart';

import '../models/leaderboard_entry.dart';

class LeaderboardService {
  final Box _localBox;
  final FirebaseFirestore? _firestore;

  LeaderboardService(this._localBox, [this._firestore]);

  bool get cloudEnabled => _firestore != null;

  List<LeaderboardEntry> loadLocalEntries() {
    final raw = _localBox.get('topLearners', defaultValue: <dynamic>[]) as List<dynamic>;
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map((map) => LeaderboardEntry.fromMap(Map<String, dynamic>.from(map)))
        .toList()
      ..sort((a, b) {
        if (b.score != a.score) return b.score.compareTo(a.score);
        return b.wins.compareTo(a.wins);
      });
  }

  Future<void> storeLocalEntries(List<LeaderboardEntry> entries) async {
    final data = entries.map((entry) => entry.toMap()).toList();
    await _localBox.put('topLearners', data);
  }

  Future<void> saveLocalEntry(String name, String schoolTag, int score, int wins) async {
    final entries = loadLocalEntries();
    final existingIndex = entries.indexWhere((entry) => entry.name == name);
    if (existingIndex != -1) {
      final current = entries[existingIndex];
      entries[existingIndex] = LeaderboardEntry(
        name: name,
        schoolTag: schoolTag.isNotEmpty ? schoolTag : current.schoolTag,
        score: max(current.score, score),
        wins: current.wins + wins,
      );
    } else {
      entries.add(LeaderboardEntry(name: name, schoolTag: schoolTag, score: score, wins: wins));
    }
    entries.sort((a, b) {
      if (b.score != a.score) return b.score.compareTo(a.score);
      return b.wins.compareTo(a.wins);
    });
    await storeLocalEntries(entries);
  }

  Future<List<LeaderboardEntry>> fetchCloudTopEntries({int limit = 20}) async {
    if (!cloudEnabled) return [];

    final querySnapshot = await _firestore!
        .collection('leaderboard')
        .orderBy('score', descending: true)
        .orderBy('wins', descending: true)
        .limit(limit)
        .get();

    return querySnapshot.docs.map((doc) {
      final data = doc.data();
      return LeaderboardEntry.fromMap(Map<String, dynamic>.from(data));
    }).toList();
  }

  Future<void> saveCloudEntry(String name, String schoolTag, int score, int wins) async {
    if (!cloudEnabled) return;

    final collection = _firestore!.collection('leaderboard');
    final querySnapshot = await collection.where('name', isEqualTo: name).limit(1).get();

    final existingEntry = querySnapshot.docs.isNotEmpty
        ? LeaderboardEntry.fromMap(Map<String, dynamic>.from(querySnapshot.docs.first.data()))
        : null;

    final cloudScore = existingEntry == null ? score : max(existingEntry.score, score);
    final cloudWins = existingEntry == null ? wins : existingEntry.wins + wins;
    final cloudTag = schoolTag.isNotEmpty ? schoolTag : (existingEntry?.schoolTag ?? '');

    final payload = {
      'name': name,
      'schoolTag': cloudTag,
      'score': cloudScore,
      'wins': cloudWins,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (existingEntry != null) {
      await collection.doc(querySnapshot.docs.first.id).set(payload);
    } else {
      await collection.add(payload);
    }
  }
}

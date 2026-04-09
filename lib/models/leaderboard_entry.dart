class LeaderboardEntry {
  final String name;
  final int score;
  final int wins;

  LeaderboardEntry({
    required this.name,
    required this.score,
    required this.wins,
  });

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'score': score,
      'wins': wins,
    };
  }

  factory LeaderboardEntry.fromMap(Map<dynamic, dynamic> map) {
    return LeaderboardEntry(
      name: map['name'] as String,
      score: map['score'] as int,
      wins: map['wins'] as int,
    );
  }
}

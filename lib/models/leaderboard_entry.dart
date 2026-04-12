class LeaderboardEntry {
  final String name;
  final String schoolTag;
  final int score;
  final int wins;

  LeaderboardEntry({
    required this.name,
    this.schoolTag = '',
    required this.score,
    required this.wins,
  });

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'schoolTag': schoolTag,
      'score': score,
      'wins': wins,
    };
  }

  factory LeaderboardEntry.fromMap(Map<dynamic, dynamic> map) {
    return LeaderboardEntry(
      name: map['name'] as String,
      schoolTag: (map['schoolTag'] as String?) ?? '',
      score: map['score'] as int,
      wins: map['wins'] as int,
    );
  }
}

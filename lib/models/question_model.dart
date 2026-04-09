enum QuestionCategory { studio, foundation, teaching }

class Question {
  final String id;
  final String text;
  final List<String> options;
  final int correctIndex;
  final String hint;
  final int points;
  final QuestionCategory category;

  Question({
    required this.id,
    required this.text,
    required this.options,
    required this.correctIndex,
    required this.hint,
    required this.points,
    required this.category,
  });
}
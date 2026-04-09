enum TileStatus { unclaimed, claimed, locked }

class TileModel {
  final int index;
  final int points;
  final int? questionIndex;
  TileStatus status;

  TileModel({
    required this.index,
    required this.points,
    this.questionIndex,
    this.status = TileStatus.unclaimed,
  });
}
class Piece {
  final int row;
  final int col;
  final bool isPlayer;
  final bool isKing;

  Piece({
    required this.row,
    required this.col,
    required this.isPlayer,
    this.isKing = false,
  });
}

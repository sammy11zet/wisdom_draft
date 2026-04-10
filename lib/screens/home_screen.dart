import 'dart:async';
import 'dart:math';

import 'package:animations/animations.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';

import '../data/questions_data.dart';
import '../models/leaderboard_entry.dart';
import '../models/piece_model.dart';
import '../models/question_model.dart';
import '../services/leaderboard_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const int boardSize = 8;
  static const Color backgroundColor = Color(0xFF1E1E1E);
  static const Color lightTileColor = Color(0xFFD7CCC8);
  static const Color darkTileColor = Color(0xFF6D4C41);
  static const Color playerColor = Color(0xFFCE1126);
  static const Color aiColor = Color(0xFF006B3F);
  static const Color accentGold = Color(0xFFFCD116);

  final Random _random = Random();
  late final Box _leaderboardBox;
  late final LeaderboardService _leaderboardService;

  bool isPlayerTurn = true;
  bool isAskingQuestion = false;
  bool gameOver = false;
  bool firstCaptureAchievement = false;
  bool madeIncorrectAnswer = false;

  List<Piece> pieces = [];
  Piece? selectedPiece;
  Piece? capturedPiece;

  int playerScore = 0;
  int coinBalance = 0;
  int currentLevel = 1;
  int currentStreak = 0;
  int wisdomOrbs = 0;
  int correctAnswerCount = 0;
  int secondsPerQuestion = 15;
  int timeRemaining = 15;
  String playerName = 'Learner';

  String statusText = 'Player turn: select a piece';
  Timer? _questionTimer;
  Set<int> usedQuestionIndexes = {};
  List<LeaderboardEntry> leaderboardEntries = [];
  List<LeaderboardEntry> cloudLeaderboardEntries = [];
  final List<String> achievements = [];
  bool cloudLeaderboardEnabled = false;
  bool isLoadingCloudLeaderboard = false;
  String cloudStatusMessage = 'Cloud leaderboard is not configured yet.';

  @override
  void initState() {
    super.initState();
    _leaderboardBox = Hive.box('leaderboard');
    _leaderboardService = LeaderboardService(
      _leaderboardBox,
      Firebase.apps.isNotEmpty ? FirebaseFirestore.instance : null,
    );
    cloudLeaderboardEnabled = _leaderboardService.cloudEnabled;
    _loadPlayerInfo();
    _loadLeaderboard();
    _initializeBoard();
    if (cloudLeaderboardEnabled) {
      _loadCloudLeaderboard();
    }
  }

  void _loadPlayerInfo() {
    final name = _leaderboardBox.get('playerName', defaultValue: 'Learner') as String;
    playerName = name;
  }

  void _storePlayerInfo() {
    _leaderboardBox.put('playerName', playerName);
  }

  void _loadLeaderboard() {
    final raw = _leaderboardBox.get('topLearners', defaultValue: <dynamic>[]) as List<dynamic>;
    leaderboardEntries = raw
        .whereType<Map<dynamic, dynamic>>()
        .map((map) => LeaderboardEntry.fromMap(Map<String, dynamic>.from(map)))
        .toList();
    leaderboardEntries.sort((a, b) {
      if (b.score != a.score) return b.score.compareTo(a.score);
      return b.wins.compareTo(a.wins);
    });
  }

  void _storeLeaderboard() {
    final data = leaderboardEntries.map((entry) => entry.toMap()).toList();
    _leaderboardBox.put('topLearners', data);
  }

  Future<void> _loadCloudLeaderboard() async {
    if (!cloudLeaderboardEnabled) return;
    setState(() {
      isLoadingCloudLeaderboard = true;
      cloudStatusMessage = 'Loading global leaderboard...';
    });

    try {
      cloudLeaderboardEntries = await _leaderboardService.fetchCloudTopEntries(limit: 20);
      if (cloudLeaderboardEntries.isEmpty) {
        cloudStatusMessage = 'No global leaderboard entries yet.';
      }
    } catch (error) {
      cloudStatusMessage = 'Failed to load global leaderboard.';
    }

    setState(() {
      isLoadingCloudLeaderboard = false;
    });
  }

  double get _aiSkill => (0.55 + (currentLevel - 1) * 0.1).clamp(0.55, 0.95);

  void _promptForPlayerName() {
    final controller = TextEditingController(text: playerName);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Enter your name'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(hintText: 'Learner name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  setState(() {
                    playerName = name;
                  });
                  _storePlayerInfo();
                }
                Navigator.pop(context);
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  void _initializeBoard({bool resetProgress = false}) {
    pieces = [];

    for (var row = 0; row < 3; row++) {
      for (var col = 0; col < boardSize; col++) {
        if ((row + col) % 2 == 1) {
          pieces.add(Piece(row: row, col: col, isPlayer: false));
        }
      }
    }

    for (var row = boardSize - 3; row < boardSize; row++) {
      for (var col = 0; col < boardSize; col++) {
        if ((row + col) % 2 == 1) {
          pieces.add(Piece(row: row, col: col, isPlayer: true));
        }
      }
    }

    if (resetProgress) {
      currentLevel = 1;
      coinBalance = 0;
    }

    selectedPiece = null;
    capturedPiece = null;
    isPlayerTurn = true;
    isAskingQuestion = false;
    gameOver = false;
    playerScore = 0;
    currentStreak = 0;
    wisdomOrbs = 0;
    correctAnswerCount = 0;
    madeIncorrectAnswer = false;
    statusText = 'Player turn: select a piece';
    timeRemaining = secondsPerQuestion;
    _questionTimer?.cancel();
    setState(() {});
  }

  Piece? _pieceAt(int row, int col) {
    for (final piece in pieces) {
      if (piece.row == row && piece.col == col) {
        return piece;
      }
    }
    return null;
  }

  bool _isDiagonalPathClear(int fromRow, int fromCol, int toRow, int toCol) {
    final rowStep = (toRow - fromRow).sign;
    final colStep = (toCol - fromCol).sign;
    var currentRow = fromRow + rowStep;
    var currentCol = fromCol + colStep;

    while (currentRow != toRow || currentCol != toCol) {
      if (_pieceAt(currentRow, currentCol) != null) {
        return false;
      }
      currentRow += rowStep;
      currentCol += colStep;
    }
    return true;
  }

  bool _isCaptureMove(Piece piece, int row, int col) {
    return (row - piece.row).abs() == 2;
  }

  List<Map<String, int>> _possibleMoves(Piece piece) {
    final moves = <Map<String, int>>[];
    for (var row = 0; row < boardSize; row++) {
      for (var col = 0; col < boardSize; col++) {
        if (_isValidMove(piece, row, col)) {
          moves.add({'row': row, 'col': col});
        }
      }
    }
    return moves;
  }

  List<Map<String, int>> _getChainCaptures(Piece piece) {
    /// Get all available capture moves for a piece (for chain captures)
    final captures = <Map<String, int>>[];
    for (var row = 0; row < boardSize; row++) {
      for (var col = 0; col < boardSize; col++) {
        if (_isValidMove(piece, row, col) && _isCaptureMove(piece, row, col)) {
          captures.add({'row': row, 'col': col});
        }
      }
    }
    return captures;
  }

  void _handleCellTap(int row, int col) {
    if (!isPlayerTurn || isAskingQuestion || gameOver) return;

    final targetPiece = _pieceAt(row, col);
    if (targetPiece != null) {
      if (targetPiece.isPlayer) {
        setState(() {
          selectedPiece = targetPiece;
          statusText = 'Selected piece at (${row + 1}, ${col + 1})';
        });
      }
      return;
    }

    if (selectedPiece == null) {
      return;
    }

    if (!_isValidMove(selectedPiece!, row, col)) {
      setState(() {
        statusText = 'Invalid destination. Select a diagonal move.';
      });
      return;
    }

    if (_isCaptureMove(selectedPiece!, row, col)) {
      _askQuestionForMove(selectedPiece!, row, col);
    } else {
      _applyMove(selectedPiece!, row, col);
      setState(() {
        statusText = 'Moved piece. AI turn.';
      });
      _endPlayerTurn();
    }
  }

  bool _isValidMove(Piece piece, int destRow, int destCol) {
    if (_pieceAt(destRow, destCol) != null) return false;
    final rowDiff = destRow - piece.row;
    final colDiff = destCol - piece.col;
    final allowedDirection = piece.isPlayer ? -1 : 1;

    if (piece.isKing) {
      // Kings move any distance diagonally
      if (rowDiff.abs() != colDiff.abs() || rowDiff == 0) return false;

      // Check for capture (jumping 2 squares)
      if (rowDiff.abs() == 2) {
        final midRow = piece.row + rowDiff ~/ 2;
        final midCol = piece.col + colDiff ~/ 2;
        final midPiece = _pieceAt(midRow, midCol);
        return midPiece != null && midPiece.isPlayer != piece.isPlayer;
      }

      // For non-capture diagonal moves, check if path is clear
      if (rowDiff.abs() > 2) {
        return _isDiagonalPathClear(piece.row, piece.col, destRow, destCol);
      }

      // Single square diagonal move
      return true;
    }

    // Normal forward move
    if (rowDiff == allowedDirection && colDiff.abs() == 1) return true;
    
    // Forward capture (2-square jump)
    if (rowDiff == 2 * allowedDirection && colDiff.abs() == 2) {
      final midRow = piece.row + rowDiff ~/ 2;
      final midCol = piece.col + colDiff ~/ 2;
      final midPiece = _pieceAt(midRow, midCol);
      return midPiece != null && midPiece.isPlayer != piece.isPlayer;
    }
    
    // Back-capture (rare opportunity): 2-square jump backward when capturing
    if (rowDiff == -2 * allowedDirection && colDiff.abs() == 2) {
      final midRow = piece.row + rowDiff ~/ 2;
      final midCol = piece.col + colDiff ~/ 2;
      final midPiece = _pieceAt(midRow, midCol);
      return midPiece != null && midPiece.isPlayer != piece.isPlayer;
    }
    
    return false;
  }

  void _askQuestionForMove(Piece piece, int destRow, int destCol) {
    final question = gesQuestions[_getNextQuestionIndex()];
    setState(() {
      isAskingQuestion = true;
      timeRemaining = secondsPerQuestion;
    });

    _questionTimer?.cancel();
    _questionTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (timeRemaining > 1) {
        setState(() {
          timeRemaining -= 1;
        });
      } else {
        timer.cancel();
        if (mounted) {
          Navigator.pop(context);
          _resolveMoveAnswer(piece, destRow, destCol, question, -1);
        }
      }
    });

    showModal(
      context: context,
      configuration: const FadeScaleTransitionConfiguration(),
      builder: (context) => AlertDialog(
        title: Text('Wisdom Trial - ${question.category.name.toUpperCase()}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              question.text,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text('Time left: $timeRemaining seconds', style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 18),
            ...List.generate(question.options.length, (index) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 50),
                    backgroundColor: Colors.brown.shade50,
                  ),
                  onPressed: () {
                    Navigator.pop(context);
                    _resolveMoveAnswer(piece, destRow, destCol, question, index);
                  },
                  child: Text(question.options[index]),
                ),
              );
            }),
          ],
        ),
      ),
    ).then((_) {
      _questionTimer?.cancel();
      _questionTimer = null;
      if (mounted) {
        setState(() {
          isAskingQuestion = false;
          timeRemaining = secondsPerQuestion;
        });
      }
    });
  }

  void _resolveMoveAnswer(
    Piece piece,
    int destRow,
    int destCol,
    Question question,
    int selectedIndex,
  ) {
    _questionTimer?.cancel();
    _questionTimer = null;

    final correct = selectedIndex == question.correctIndex;
    if (selectedIndex == -1) {
      _showMessage('Time Up', 'You ran out of time.', Colors.red);
    }

    if (correct && selectedIndex != -1) {
      final earnedCoins = 5 + timeRemaining * 2;
      final captureBonus = _isCaptureMove(piece, destRow, destCol) ? 10 : 0;
      coinBalance += earnedCoins + captureBonus;
      playerScore += question.points;
      correctAnswerCount += 1;
      currentStreak += 1;
      wisdomOrbs += 1;
      _unlockAchievement('Wise Streak', 'Current streak: $currentStreak');

      if (currentStreak == 5) {
        _unlockAchievement('Wisdom Warrior', '5 correct answers in a row');
        wisdomOrbs += 1;
      }

      if (_isCaptureMove(piece, destRow, destCol) && !firstCaptureAchievement) {
        firstCaptureAchievement = true;
        _unlockAchievement('First Capture', 'You earned your first capture.');
      }

      _applyMove(piece, destRow, destCol);
      _playSuccessSound();
      _showMessage('Correct! +${earnedCoins + captureBonus} coins', 'Move unlocked and scored.', Colors.green);

      // Future.delayed is used to ensure the piece has been updated in the UI
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted && isPlayerTurn) {
          // Check for chain captures after the move is applied
          final movedPiece = _pieceAt(destRow, destCol);
          if (movedPiece != null && _isCaptureMove(piece, destRow, destCol)) {
            final chainCaptures = _getChainCaptures(movedPiece);
            if (chainCaptures.isNotEmpty) {
              // Chain captures available - keep the piece selected and allow next capture
              setState(() {
                selectedPiece = movedPiece;
                statusText = 'Chain capture available! Select your next move.';
              });
              return;
            }
          }
          // No chain captures - end the turn
          _endPlayerTurn();
        }
      });
    } else {
      madeIncorrectAnswer = true;
      currentStreak = 0;
      _playErrorSound();
      _showMessage('Incorrect', 'You lost your turn.', Colors.red);
      setState(() {
        selectedPiece = null;
        statusText = 'Wrong answer. AI turn.';
      });
      _endPlayerTurn();
    }
  }

  void _unlockAchievement(String title, String subtitle) {
    _playSuccessSound();
    final achievement = '$title: $subtitle';
    if (!achievements.contains(achievement)) {
      achievements.insert(0, achievement);
      if (achievements.length > 5) {
        achievements.removeLast();
      }
      _showMessage('Achievement unlocked', achievement, accentGold);
    }
  }

  void _applyMove(Piece piece, int destRow, int destCol) {
    final captured = _capturePieceForMove(piece, destRow, destCol);
    final movedPiece = Piece(
      row: destRow,
      col: destCol,
      isPlayer: piece.isPlayer,
      isKing: piece.isKing || _shouldBeKing(piece, destRow),
    );

    final index = pieces.indexOf(piece);
    if (index != -1) {
      setState(() {
        pieces[index] = movedPiece;
        selectedPiece = movedPiece;
        if (captured != null) {
          capturedPiece = captured;
        }
      });

      if (captured != null) {
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) {
            setState(() {
              pieces.remove(capturedPiece);
              capturedPiece = null;
            });
            _checkWinCondition();
          }
        });
      } else {
        _checkWinCondition();
      }
    }
  }

  void _checkWinCondition() {
    if (pieces.where((p) => p.isPlayer).isEmpty) {
      gameOver = true;
      _showMessage('Game Over', 'AI wins!', Colors.red);
      setState(() {
        statusText = 'AI wins!';
      });
      _showDefeatDialog();
      return;
    }

    if (pieces.where((p) => !p.isPlayer).isEmpty) {
      gameOver = true;
      currentLevel += 1;
      _showMessage('Game Over', 'Player wins!', Colors.green);
      setState(() {
        statusText = 'Level $currentLevel unlocked!';
      });
      if (!madeIncorrectAnswer) {
        _unlockAchievement('Flawless Victory', 'Win without mistakes');
      }
      _showVictoryDialog();
    }
  }

  Piece? _capturePieceForMove(Piece piece, int destRow, int destCol) {
    final rowDiff = destRow - piece.row;
    final colDiff = destCol - piece.col;
    if (rowDiff.abs() != 2 || colDiff.abs() != 2) return null;

    final midRow = piece.row + rowDiff ~/ 2;
    final midCol = piece.col + colDiff ~/ 2;
    final midPiece = _pieceAt(midRow, midCol);
    if (midPiece != null && midPiece.isPlayer != piece.isPlayer) {
      return midPiece;
    }
    return null;
  }

  bool _shouldBeKing(Piece piece, int destRow) {
    if (piece.isKing) return true;
    return piece.isPlayer ? destRow == 0 : destRow == boardSize - 1;
  }

  void _endPlayerTurn() {
    if (gameOver) return;
    setState(() {
      selectedPiece = null;
      isPlayerTurn = false;
      statusText = 'AI thinking...';
    });
    Future.delayed(const Duration(milliseconds: 800), _aiTurn);
  }

  void _aiTurn() {
    if (gameOver) return;
    final aiPieces = pieces.where((piece) => !piece.isPlayer).toList();
    final validMoves = <Map<String, dynamic>>[];

    for (final piece in aiPieces) {
      for (var row = 0; row < boardSize; row++) {
        for (var col = 0; col < boardSize; col++) {
          if (_isValidMove(piece, row, col)) {
            validMoves.add({'piece': piece, 'row': row, 'col': col});
          }
        }
      }
    }

    if (validMoves.isEmpty) {
      setState(() {
        isPlayerTurn = true;
        statusText = 'AI can’t move. Player turn.';
      });
      return;
    }

    final captureMoves = validMoves.where((move) {
      final piece = move['piece'] as Piece;
      final row = move['row'] as int;
      final col = move['col'] as int;
      return _isCaptureMove(piece, row, col);
    }).toList();

    if (captureMoves.isNotEmpty) {
      final didAnswer = _random.nextInt(100) < (_aiSkill * 100).toInt();
      if (!didAnswer) {
        setState(() {
          isPlayerTurn = true;
          statusText = 'AI missed its capture challenge.';
        });
        return;
      }
    }

    final moveList = captureMoves.isNotEmpty ? captureMoves : validMoves;
    Map<String, dynamic> move;
    if (captureMoves.isEmpty && currentLevel >= 3) {
      moveList.sort((a, b) {
        final aRow = (a['row'] as int);
        final bRow = (b['row'] as int);
        return bRow.compareTo(aRow);
      });
      move = moveList.first;
    } else {
      move = moveList[_random.nextInt(moveList.length)];
    }
    final piece = move['piece'] as Piece;
    final row = move['row'] as int;
    final col = move['col'] as int;

    _applyMove(piece, row, col);

    setState(() {
      isPlayerTurn = true;
      statusText = 'AI moved. Player turn.';
    });
  }

  void _showVictoryDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF121212),
          title: Column(
            children: const [
              Icon(Icons.emoji_events, size: 60, color: Color(0xFFFCD116)),
              SizedBox(height: 12),
              Text('Congratulations!', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('You have won this match and unlocked Level $currentLevel.', style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 16),
              Text('Coins earned: $coinBalance', style: const TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              const Text('AI will become stronger for the next round.', style: TextStyle(color: Colors.white70)),
            ],
          ),
          actions: [
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _promptSaveScore();
              },
              style: ElevatedButton.styleFrom(backgroundColor: accentGold, foregroundColor: Colors.black),
              child: const Text('Save Score'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _initializeBoard();
              },
              child: const Text('Next Level', style: TextStyle(color: Colors.white70)),
            ),
          ],
        );
      },
    );
  }

  void _showDefeatDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF121212),
          title: Column(
            children: const [
              Icon(Icons.sentiment_dissatisfied, size: 60, color: Colors.redAccent),
              SizedBox(height: 12),
              Text('Game Over', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
            ],
          ),
          content: const Text('AI has won this match. Try again to climb levels and earn more coins.', style: TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _initializeBoard(resetProgress: false);
              },
              child: const Text('Play Again', style: TextStyle(color: Colors.white70)),
            ),
          ],
        );
      },
    );
  }

  void _showMessage(String title, String body, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$title $body'),
        backgroundColor: color,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _playSuccessSound() {
    SystemSound.play(SystemSoundType.click);
  }

  void _playErrorSound() {
    SystemSound.play(SystemSoundType.alert);
  }

  String _artMasterRankLabel() {
    if (playerScore >= 450) {
      return 'Art Master';
    }
    if (playerScore >= 250) {
      return 'Senior Scholar';
    }
    return 'Art Apprentice';
  }

  int _getNextQuestionIndex() {
    final available = List.generate(gesQuestions.length, (i) => i)
        .where((i) => !usedQuestionIndexes.contains(i))
        .toList();

    if (available.isEmpty) {
      usedQuestionIndexes.clear();
      return _getNextQuestionIndex();
    }

    final next = available[_random.nextInt(available.length)];
    usedQuestionIndexes.add(next);
    return next;
  }

  void _promptSaveScore() {
    final nameController = TextEditingController(text: 'Learner');
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Save your score'),
          content: TextField(
            controller: nameController,
            decoration: const InputDecoration(labelText: 'Your name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final name = nameController.text.trim();
                if (name.isEmpty) return;
                Navigator.pop(context);
                _saveLeaderboardEntry(name);
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  void _saveLeaderboardEntry(String name) async {
    final existingIndex = leaderboardEntries.indexWhere((entry) => entry.name == name);
    if (existingIndex != -1) {
      final current = leaderboardEntries[existingIndex];
      leaderboardEntries[existingIndex] = LeaderboardEntry(
        name: name,
        score: max(current.score, playerScore),
        wins: current.wins + 1,
      );
    } else {
      leaderboardEntries.add(
        LeaderboardEntry(name: name, score: playerScore, wins: 1),
      );
    }
    leaderboardEntries.sort((a, b) {
      if (b.score != a.score) return b.score.compareTo(a.score);
      return b.wins.compareTo(a.wins);
    });
    _storeLeaderboard();

    if (cloudLeaderboardEnabled) {
      await _leaderboardService.saveCloudEntry(name, playerScore, 1);
      await _loadCloudLeaderboard();
    }

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      floatingActionButton: FloatingActionButton(
        onPressed: _showLeaderboardDialog,
        backgroundColor: accentGold,
        foregroundColor: Colors.black,
        child: const Icon(Icons.leaderboard),
      ),
      body: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: Center(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  double size = constraints.maxWidth < 600
                      ? constraints.maxWidth * 0.95
                      : 550;
                  double boardSize = size < constraints.maxHeight * 0.8
                      ? size
                      : constraints.maxHeight * 0.8;

                  return SizedBox(
                    width: boardSize,
                    height: boardSize,
                    child: GridView.builder(
                      itemCount: 8 * 8,
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 8,
                        crossAxisSpacing: 4,
                        mainAxisSpacing: 4,
                        childAspectRatio: 1.0,
                      ),
                      itemBuilder: (context, index) {
                        final row = index ~/ 8;
                        final col = index % 8;
                        return _buildBoardCell(row, col);
                      },
                    ),
                  );
                },
              ),
            ),
          ),
          _buildFooter(),
        ],
      ),
    );
  }

  void _showLeaderboardDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2a2a2a),
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Top Learners', style: TextStyle(color: accentGold, fontWeight: FontWeight.bold)),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (cloudLeaderboardEnabled) ...[
                const Text('Global Leaderboard', style: TextStyle(color: accentGold, fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                if (isLoadingCloudLeaderboard)
                  const CircularProgressIndicator(color: accentGold)
                else if (cloudLeaderboardEntries.isEmpty)
                  Text(cloudStatusMessage, style: const TextStyle(color: Colors.white54))
                else
                  Column(
                    children: [
                      ...cloudLeaderboardEntries.take(10).toList().asMap().entries.map((entry) {
                        final index = entry.key + 1;
                        final data = entry.value;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('#$index', style: const TextStyle(color: accentGold, fontWeight: FontWeight.bold)),
                              Expanded(
                                child: Text(data.name, style: const TextStyle(color: Colors.white), overflow: TextOverflow.ellipsis),
                              ),
                              Text('${data.score}pts', style: const TextStyle(color: Colors.white70)),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                const Divider(color: Colors.white24),
              ] else ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Text(
                    cloudStatusMessage,
                    style: const TextStyle(color: Colors.white54),
                    textAlign: TextAlign.center,
                  ),
                ),
                const Divider(color: Colors.white24),
              ],
              const SizedBox(height: 12),
              const Text('Local Leaderboard', style: TextStyle(color: accentGold, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              if (leaderboardEntries.isEmpty)
                const Text('No local entries yet.', style: TextStyle(color: Colors.white54))
              else
                Column(
                  children: [
                    ...leaderboardEntries.take(10).toList().asMap().entries.map((entry) {
                      final index = entry.key + 1;
                      final data = entry.value;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('#$index', style: const TextStyle(color: accentGold, fontWeight: FontWeight.bold)),
                            Expanded(
                              child: Text(data.name, style: const TextStyle(color: Colors.white), overflow: TextOverflow.ellipsis),
                            ),
                            Text('${data.score}pts', style: const TextStyle(color: Colors.white70)),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              const Divider(color: Colors.white24),
              const SizedBox(height: 10),
              Text(
                'Your Rank: ${_artMasterRankLabel()}',
                style: const TextStyle(color: accentGold, fontWeight: FontWeight.bold),
              ),
              Text(
                'Score: $playerScore',
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final turnColor = isPlayerTurn ? playerColor : aiColor;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [turnColor.withAlpha(242), backgroundColor],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(30),
          bottomRight: Radius.circular(30),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'WISDOM DRAFT',
                style: GoogleFonts.philosopher(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'GES Art Studio & Foundation',
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: accentGold.withAlpha(180),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'TeamGrok',
                  style: GoogleFonts.philosopher(
                    color: Colors.black87,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _buildMetricChip('Score', playerScore.toString(), accentGold),
                  const SizedBox(width: 10),
                  _buildMetricChip('Orbs', wisdomOrbs.toString(), accentGold.withAlpha(217)),
                ],
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                isPlayerTurn ? 'PLAYER TURN' : 'AI TURN',
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                isAskingQuestion ? 'Answer in $timeRemaining s' : statusText,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 8),
              _buildTurnIndicator(isPlayerTurn),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetricChip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withAlpha(46),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          Text(
            '$label: ',
            style: TextStyle(color: color.withAlpha(242), fontWeight: FontWeight.bold),
          ),
          Text(value, style: TextStyle(color: color.withAlpha(242), fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildTurnIndicator(bool playerTurn) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: playerTurn ? playerColor.withAlpha(102) : aiColor.withAlpha(102),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        playerTurn ? 'Red Glow: Your Move' : 'Green Glow: AI Move',
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
    );
  }

  Widget _buildBoardCell(int row, int col) {
    final piece = _pieceAt(row, col);
    final isSelected = selectedPiece != null && piece == selectedPiece;
    final validMoves = selectedPiece != null ? _possibleMoves(selectedPiece!) : [];
    final isPossibleMove = validMoves.any((move) => move['row'] == row && move['col'] == col);
    final isCaptureDestination = selectedPiece != null && isPossibleMove && _isCaptureMove(selectedPiece!, row, col);
    final tileColor = (row + col) % 2 == 1 ? darkTileColor : lightTileColor;
    final pieceColor = piece?.isPlayer == true ? playerColor : aiColor;

    return GestureDetector(
      onTap: () => _handleCellTap(row, col),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        decoration: BoxDecoration(
          color: tileColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? accentGold : Colors.transparent,
            width: isSelected ? 3 : 1,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: accentGold.withAlpha(128),
                    blurRadius: 14,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: Stack(
          children: [
            if (isPossibleMove)
              const Positioned(
                bottom: 8,
                right: 8,
                child: Icon(
                  Icons.circle,
                  size: 10,
                  color: accentGold,
                ),
              ),
            if (isCaptureDestination)
              Positioned.fill(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withAlpha(46),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.redAccent, width: 3),
                  ),
                ),
              ),
            if (piece != null)
              Center(
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 300),
                  opacity: piece == capturedPiece ? 0.0 : 1.0,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: pieceColor,
                      border: Border.all(color: Colors.black26, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: isSelected ? accentGold.withAlpha(191) : Colors.black.withAlpha(77),
                          blurRadius: isSelected ? 16 : 8,
                          spreadRadius: isSelected ? 1 : 0,
                        ),
                      ],
                    ),
                    child: piece.isKing
                        ? const Icon(Icons.star, size: 20, color: Colors.white)
                        : null,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter() {
    final playerCount = pieces.where((piece) => piece.isPlayer).length;
    final aiCount = pieces.where((piece) => !piece.isPlayer).length;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _miniStat('Player', '$playerCount'),
          _miniStat('AI', '$aiCount'),
          _miniStat('Streak', '$currentStreak'),
          ElevatedButton.icon(
            onPressed: _initializeBoard,
            icon: const Icon(Icons.refresh),
            label: const Text('Reset'),
            style: ElevatedButton.styleFrom(
              backgroundColor: accentGold,
              foregroundColor: Colors.black,
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniStat(String label, String value) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: Colors.white70),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ],
    );
  }






}

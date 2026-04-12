import 'dart:async';
import 'dart:math';

import 'package:animations/animations.dart';
import 'package:audioplayers/audioplayers.dart';
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

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
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

  static const int _maxCapturesPerTurn = 3;

  bool isPlayerTurn = true;
  bool isAskingQuestion = false;
  bool gameOver = false;
  bool firstCaptureAchievement = false;
  bool madeIncorrectAnswer = false;
  int _consecutiveCaptureCount = 0;
  bool _audioStarted = false;

  List<Piece> pieces = [];
  Piece? selectedPiece;
  Piece? capturedPiece;

  int playerScore = 0;
  int coinBalance = 0;
  int currentLevel = 1;
  int currentStreak = 0;
  int wisdomOrbs = 0;
  int correctAnswerCount = 0;
  int secondsPerQuestion = 20;
  int timeRemaining = 15;
  String playerName = 'Learner';
  String schoolTag = '';

  String statusText = 'Player turn: select a piece';
  Timer? _questionTimer;
  List<int> _shuffledQuestionIndices = [];
  int _currentQuestionPosition = 0;
  List<LeaderboardEntry> leaderboardEntries = [];
  List<LeaderboardEntry> cloudLeaderboardEntries = [];
  final List<String> achievements = [];
  bool cloudLeaderboardEnabled = false;
  bool isLoadingCloudLeaderboard = false;
  String cloudStatusMessage = 'Cloud leaderboard is not configured yet.';

  AudioPlayer? _backgroundPlayer;
  AudioPlayer? _loopPlayer;
  final Map<String, AudioPlayer> _soundPlayers = {};

  late AnimationController _coinController;
  late Animation<double> _coinAnimation;
  bool showCoinBurst = false;
  final int _burstCoinCount = 6;
  Offset coinStartPosition = const Offset(200, 400);
  Offset coinEndPosition = const Offset(300, 80);
  List<Offset> _coinBurstOffsets = [];
  final GlobalKey scoreKey = GlobalKey();

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
    _initializeAudio();
    _coinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _coinAnimation = CurvedAnimation(
      parent: _coinController,
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    for (final p in _soundPlayers.values) {
      try { p.dispose(); } catch (_) {}
    }
    try { _backgroundPlayer?.dispose(); } catch (_) {}
    try { _loopPlayer?.dispose(); } catch (_) {}
    _coinController.dispose();
    super.dispose();
  }

  void _loadPlayerInfo() {
    playerName =
        _leaderboardBox.get('playerName', defaultValue: 'Learner') as String;
    schoolTag =
        _leaderboardBox.get('schoolTag', defaultValue: '') as String;
  }

  void _storePlayerInfo() {
    _leaderboardBox.put('playerName', playerName);
    _leaderboardBox.put('schoolTag', schoolTag);
  }

  void _loadLeaderboard() {
    final raw = _leaderboardBox.get('topLearners', defaultValue: <dynamic>[])
        as List<dynamic>;
    leaderboardEntries = raw
        .whereType<Map<dynamic, dynamic>>()
        .map((map) => LeaderboardEntry.fromMap(Map<String, dynamic>.from(map)))
        .toList();
    leaderboardEntries.sort((a, b) {
      if (b.score != a.score) return b.score.compareTo(a.score);
      return b.wins.compareTo(a.wins);
    });
  }

  // One dedicated AudioPlayer per effect sound — pre-loaded so playback is instant.
  static const _effectKeys = {
    'select':    'audio/select.mp3',
    'move':      'audio/move.mp3',
    'capture':   'audio/capture.mp3',
    'promotion': 'audio/promotion.mp3',
    'wrong':     'audio/wrong.mp3',
    'win':       'audio/win.mp3',
    'turn':      'audio/turn.mp3',
  };

  void _initializeAudio() async {
    // Pre-load every effect sound into its own player.
    for (final entry in _effectKeys.entries) {
      try {
        final p = AudioPlayer();
        await p.setVolume(1.0);
        await p.setReleaseMode(ReleaseMode.stop);
        await p.setSource(AssetSource(entry.value));
        _soundPlayers[entry.key] = p;
      } catch (_) {}
    }

    // Pre-load question loop player.
    try {
      _loopPlayer = AudioPlayer();
      await _loopPlayer!.setVolume(1.0);
      await _loopPlayer!.setReleaseMode(ReleaseMode.loop);
      await _loopPlayer!.setSource(AssetSource('audio/question.mp3'));
    } catch (_) {}

    // Pre-load background player — source ready, waits for first tap to resume.
    try {
      _backgroundPlayer = AudioPlayer();
      await _backgroundPlayer!.setVolume(0.3);
      await _backgroundPlayer!.setReleaseMode(ReleaseMode.loop);
      await _backgroundPlayer!.setSource(AssetSource('audio/background.mp3'));
    } catch (_) {}
  }

  // Called on first user tap — satisfies browser autoplay policy.
  void _startBackgroundIfNeeded() async {
    if (_audioStarted) return;
    _audioStarted = true;
    try {
      await _backgroundPlayer?.resume();
    } catch (_) {}
  }

  // Replay a pre-loaded effect sound with zero latency.
  void _playEffectSound(String key) async {
    final p = _soundPlayers[key];
    if (p == null) return;
    try {
      await p.seek(Duration.zero);
      await p.resume();
    } catch (_) {}
  }

  void _playSelectSound()    => _playEffectSound('select');
  void _playMoveSound()      => _playEffectSound('move');
  void _playCaptureSound()   => _playEffectSound('capture');
  void _playCorrectSound()   => _playEffectSound('promotion');
  void _playWrongSound()     => _playEffectSound('wrong');
  void _playPromotionSound() => _playEffectSound('promotion');
  void _playWinSound()       => _playEffectSound('win');
  void _playTurnChangeSound() => _playEffectSound('turn');

  void _playQuestionSound() async {
    try {
      await _loopPlayer?.seek(Duration.zero);
      await _loopPlayer?.resume();
    } catch (_) {}
  }

  void _stopQuestionSound() {
    try { _loopPlayer?.stop(); } catch (_) {}
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
      cloudLeaderboardEntries =
          await _leaderboardService.fetchCloudTopEntries(limit: 20);
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
    _consecutiveCaptureCount = 0;

    // Shuffle all question indices for this game
    _shuffledQuestionIndices = List.generate(gesQuestions.length, (i) => i);
    _shuffledQuestionIndices.shuffle(_random);
    _currentQuestionPosition = 0;

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

  Piece? _findKingCapturePiece(Piece piece, int destRow, int destCol) {
    if (!piece.isKing) return null;

    final rowDiff = destRow - piece.row;
    final colDiff = destCol - piece.col;
    if (rowDiff.abs() != colDiff.abs() || rowDiff == 0) return null;

    final rowStep = rowDiff.sign;
    final colStep = colDiff.sign;
    var currentRow = piece.row + rowStep;
    var currentCol = piece.col + colStep;
    Piece? captured;

    while (currentRow != destRow && currentCol != destCol) {
      final currentPiece = _pieceAt(currentRow, currentCol);
      if (currentPiece != null) {
        if (currentPiece.isPlayer == piece.isPlayer) {
          return null;
        }
        if (captured != null) {
          return null;
        }
        captured = currentPiece;
      }
      currentRow += rowStep;
      currentCol += colStep;
    }
    return captured;
  }

  bool _isCaptureMove(Piece piece, int row, int col) {
    if (!piece.isKing) {
      return (row - piece.row).abs() == 2 && (col - piece.col).abs() == 2;
    }
    return _findKingCapturePiece(piece, row, col) != null;
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

  List<Map<String, int>> _playerCaptureMoves() {
    final captures = <Map<String, int>>[];
    for (final piece in pieces.where((piece) => piece.isPlayer)) {
      for (var row = 0; row < boardSize; row++) {
        for (var col = 0; col < boardSize; col++) {
          if (_isValidMove(piece, row, col) &&
              _isCaptureMove(piece, row, col)) {
            captures
                .add({'piece': pieces.indexOf(piece), 'row': row, 'col': col});
          }
        }
      }
    }
    return captures;
  }

  bool _playerHasCaptureMove() {
    return _playerCaptureMoves().isNotEmpty;
  }

  void _handleCellTap(int row, int col) {
    _startBackgroundIfNeeded();
    if (!isPlayerTurn || isAskingQuestion || gameOver) {
      return;
    }

    final targetPiece = _pieceAt(row, col);
    if (targetPiece != null) {
      if (targetPiece.isPlayer) {
        _playSelectSound();
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

    final hasMandatoryCapture = _playerHasCaptureMove();
    final selectedCaptureMoves = _getChainCaptures(selectedPiece!);
    final selectedMoveIsCapture = _isCaptureMove(selectedPiece!, row, col);

    if (hasMandatoryCapture && !selectedMoveIsCapture) {
      if (selectedCaptureMoves.isEmpty) {
        setState(() {
          statusText =
              'A capture is available. Select a capturing piece first.';
        });
        return;
      }
      setState(() {
        statusText = 'You must capture when possible.';
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

      // Capture move can be any diagonal landing past an enemy piece
      if (_findKingCapturePiece(piece, destRow, destCol) != null) {
        return true;
      }

      // For non-capture diagonal moves, check if path is clear
      return _isDiagonalPathClear(piece.row, piece.col, destRow, destCol);
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
    _playCaptureSound();
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

    _playQuestionSound();
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
            Text('Time left: $timeRemaining seconds',
                style: const TextStyle(fontWeight: FontWeight.w600)),
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
                    _resolveMoveAnswer(
                        piece, destRow, destCol, question, index);
                  },
                  child: Text(question.options[index]),
                ),
              );
            }),
          ],
        ),
      ),
    ).then((_) {
      _stopQuestionSound();
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
    _stopQuestionSound();
    _questionTimer?.cancel();
    _questionTimer = null;

    final correct = selectedIndex == question.correctIndex;
    if (selectedIndex == -1) {
      _showMessage('Time Up', 'You ran out of time.', Colors.red);
    }

    if (correct && selectedIndex != -1) {
      // Speed-based coin rewards
      int baseCoins;
      final timeUsed = secondsPerQuestion - timeRemaining;
      if (timeUsed < 5) {
        baseCoins = 50; // Under 5 seconds
      } else if (timeUsed < 10) {
        baseCoins = 30; // Under 10 seconds
      } else {
        baseCoins = 20; // Within 20 seconds
      }

      final captureBonus = _isCaptureMove(piece, destRow, destCol) ? 10 : 0;
      final earnedCoins = baseCoins + captureBonus;
      coinBalance += earnedCoins;
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
      _playCorrectSound();
      // Use default board center position for coin animation start
      _showCoinAnimation(earnedCoins, const Offset(200, 400));
      _showMessage('Correct! +$earnedCoins coins', 'Move unlocked and scored.',
          Colors.green);

      _consecutiveCaptureCount += 1;

      // Future.delayed is used to ensure the piece has been updated in the UI
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted && isPlayerTurn) {
          // Allow chain captures only if under the per-turn cap
          final movedPiece = _pieceAt(destRow, destCol);
          if (_consecutiveCaptureCount < _maxCapturesPerTurn &&
              movedPiece != null &&
              _isCaptureMove(piece, destRow, destCol)) {
            final chainCaptures = _getChainCaptures(movedPiece);
            if (chainCaptures.isNotEmpty) {
              setState(() {
                selectedPiece = movedPiece;
                statusText = 'Chain capture! Select your next capture.';
              });
              return;
            }
          }
          // No chain captures or cap reached — end the turn
          _endPlayerTurn();
        }
      });
    } else {
      madeIncorrectAnswer = true;
      currentStreak = 0;
      _playWrongSound();
      _showMessage('Incorrect', 'You lost your turn.', Colors.red);
      setState(() {
        selectedPiece = null;
        statusText = 'Wrong answer. AI turn.';
      });
      _endPlayerTurn();
    }
  }

  void _unlockAchievement(String title, String subtitle) {
    _playCorrectSound();
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

      if (!piece.isKing && _shouldBeKing(piece, destRow)) {
        _playPromotionSound();
      }

      if (captured != null) {
        _playMoveSound(); // For capture move, still play move after capture sound
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
        _playMoveSound();
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
      _playWinSound();
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
    if (piece.isKing) {
      return _findKingCapturePiece(piece, destRow, destCol);
    }

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
    _consecutiveCaptureCount = 0;
    _playTurnChangeSound();
    setState(() {
      selectedPiece = null;
      isPlayerTurn = false;
      statusText = 'AI thinking...';
    });
    Future.delayed(const Duration(milliseconds: 800), () => _aiTurn(0));
  }

  void _aiTurn(int captureCount, [Piece? chainPiece]) {
    if (gameOver) return;

    List<Map<String, dynamic>> validMoves;

    if (chainPiece != null) {
      // Chaining: only capture moves for the same piece
      validMoves = [];
      for (var row = 0; row < boardSize; row++) {
        for (var col = 0; col < boardSize; col++) {
          if (_isValidMove(chainPiece, row, col) &&
              _isCaptureMove(chainPiece, row, col)) {
            validMoves.add({'piece': chainPiece, 'row': row, 'col': col});
          }
        }
      }
      if (validMoves.isEmpty) {
        setState(() {
          isPlayerTurn = true;
          statusText = 'AI moved. Player turn.';
        });
        return;
      }
    } else {
      // Normal turn: all AI pieces
      validMoves = [];
      final aiPieces = pieces.where((p) => !p.isPlayer).toList();
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
          statusText = "AI can't move. Player turn.";
        });
        return;
      }

      // Prefer captures on a normal turn
      final captureMoves = validMoves.where((move) {
        final p = move['piece'] as Piece;
        final r = move['row'] as int;
        final c = move['col'] as int;
        return _isCaptureMove(p, r, c);
      }).toList();

      if (captureMoves.isNotEmpty) {
        validMoves = captureMoves;
      } else if (currentLevel >= 3) {
        validMoves.sort((a, b) =>
            (b['row'] as int).compareTo(a['row'] as int));
      }
    }

    final move = validMoves[_random.nextInt(validMoves.length)];
    final piece = move['piece'] as Piece;
    final row = move['row'] as int;
    final col = move['col'] as int;

    final isCapture = _isCaptureMove(piece, row, col);
    _applyMove(piece, row, col);

    if (isCapture) {
      // Wait for _applyMove's 300ms captured-piece removal before checking
      // chain captures — otherwise the dead piece is still on the board and
      // _getChainCaptures incorrectly finds it as a jump target.
      Future.delayed(const Duration(milliseconds: 350), () {
        if (!mounted || gameOver) return;
        if (captureCount + 1 < _maxCapturesPerTurn) {
          final movedPiece = _pieceAt(row, col);
          if (movedPiece != null && _getChainCaptures(movedPiece).isNotEmpty) {
            setState(() {
              isPlayerTurn = false;
              statusText = 'AI continues capture...';
            });
            Future.delayed(const Duration(milliseconds: 600),
                () => _aiTurn(captureCount + 1, movedPiece));
            return;
          }
        }
        setState(() {
          isPlayerTurn = true;
          statusText = 'AI moved. Player turn.';
        });
      });
    } else {
      setState(() {
        isPlayerTurn = true;
        statusText = 'AI moved. Player turn.';
      });
    }
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
              Text('Congratulations!',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('You have won this match and unlocked Level $currentLevel.',
                  style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 16),
              Text('Coins earned: $coinBalance',
                  style: const TextStyle(
                      color: Colors.amberAccent, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              const Text('AI will become stronger for the next round.',
                  style: TextStyle(color: Colors.white70)),
            ],
          ),
          actions: [
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _promptSaveScore();
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: accentGold, foregroundColor: Colors.black),
              child: const Text('Save Score'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _initializeBoard();
              },
              child: const Text('Next Level',
                  style: TextStyle(color: Colors.white70)),
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
              Icon(Icons.sentiment_dissatisfied,
                  size: 60, color: Colors.redAccent),
              SizedBox(height: 12),
              Text('Game Over',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          content: const Text(
              'AI has won this match. Try again to climb levels and earn more coins.',
              style: TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _initializeBoard(resetProgress: false);
              },
              child: const Text('Play Again',
                  style: TextStyle(color: Colors.white70)),
            ),
          ],
        );
      },
    );
  }

  void _showCoinAnimation(int coins, Offset startPosition) {
    _coinBurstOffsets = List.generate(
      _burstCoinCount,
      (index) => Offset(
        (_random.nextDouble() * 60) - 30,
        (_random.nextDouble() * 40) - 20,
      ),
    );

    // Get the score widget position
    Offset endPosition = _getScorePosition();

    setState(() {
      coinStartPosition = startPosition;
      coinEndPosition = endPosition;
      showCoinBurst = true;
    });

    _coinController.forward(from: 0).then((_) {
      if (!mounted) return;
      setState(() {
        showCoinBurst = false;
      });
    });
  }

  Offset _getScorePosition() {
    try {
      final box = scoreKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null) {
        final offset = box.localToGlobal(Offset.zero);
        return offset + Offset(box.size.width / 2, box.size.height / 2);
      }
    } catch (_) {
      // Silent fail, fallback to default
    }
    return const Offset(300, 80);
  }

  Widget _buildCoinAnimation() {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: true,
        child: AnimatedBuilder(
          animation: _coinAnimation,
          builder: (context, child) {
            final dx = coinStartPosition.dx +
                (coinEndPosition.dx - coinStartPosition.dx) *
                    _coinAnimation.value;
            final dy = coinStartPosition.dy +
                (coinEndPosition.dy - coinStartPosition.dy) *
                    _coinAnimation.value;

            return Stack(
              children: _coinBurstOffsets.map((offset) {
                final coinX = dx + offset.dx * (1 - _coinAnimation.value);
                final coinY = dy + offset.dy * (1 - _coinAnimation.value);
                return Positioned(
                  left: coinX,
                  top: coinY,
                  child: Opacity(
                    opacity: 1 - _coinAnimation.value,
                    child: Transform.rotate(
                      angle: _coinAnimation.value * 6.28,
                      child: Transform.scale(
                        scale: 1 - (_coinAnimation.value * 0.6),
                        child: child,
                      ),
                    ),
                  ),
                );
              }).toList(),
            );
          },
          child: _buildCoinImage(),
        ),
      ),
    );
  }

  Widget _buildCoinImage() {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: accentGold,
        boxShadow: [
          BoxShadow(
            color: accentGold.withAlpha(115),
            blurRadius: 12,
            spreadRadius: 3,
          ),
        ],
      ),
      child: const Icon(Icons.monetization_on, color: Colors.white, size: 24),
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
    if (_currentQuestionPosition >= _shuffledQuestionIndices.length) {
      // Reshuffle when we've gone through all questions
      _shuffledQuestionIndices.shuffle(_random);
      _currentQuestionPosition = 0;
    }

    final index = _shuffledQuestionIndices[_currentQuestionPosition];
    _currentQuestionPosition++;
    return index;
  }

  void _promptSaveScore() {
    final nameController = TextEditingController(text: playerName);
    final tagController = TextEditingController(text: schoolTag);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2a2a2a),
          title: const Text('Save your score',
              style: TextStyle(color: accentGold, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Your name',
                  labelStyle: TextStyle(color: Colors.white54),
                  enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white24)),
                  focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: accentGold)),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: tagController,
                style: const TextStyle(color: Colors.white),
                maxLength: 10,
                decoration: const InputDecoration(
                  labelText: 'School tag (max 10 chars)',
                  labelStyle: TextStyle(color: Colors.white54),
                  hintText: 'e.g. GHANASS',
                  hintStyle: TextStyle(color: Colors.white24),
                  counterStyle: TextStyle(color: Colors.white38),
                  enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white24)),
                  focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: accentGold)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: accentGold),
              onPressed: () {
                final name = nameController.text.trim();
                if (name.isEmpty) return;
                final tag = tagController.text.trim();
                setState(() {
                  playerName = name;
                  schoolTag = tag;
                });
                _storePlayerInfo();
                Navigator.pop(context);
                _saveLeaderboardEntry(name, tag);
              },
              child: const Text('Save', style: TextStyle(color: Colors.black)),
            ),
          ],
        );
      },
    );
  }

  void _saveLeaderboardEntry(String name, String tag) async {
    final existingIndex =
        leaderboardEntries.indexWhere((entry) => entry.name == name);
    if (existingIndex != -1) {
      final current = leaderboardEntries[existingIndex];
      leaderboardEntries[existingIndex] = LeaderboardEntry(
        name: name,
        schoolTag: tag.isNotEmpty ? tag : current.schoolTag,
        score: max(current.score, playerScore),
        wins: current.wins + 1,
      );
    } else {
      leaderboardEntries.add(
        LeaderboardEntry(name: name, schoolTag: tag, score: playerScore, wins: 1),
      );
    }
    leaderboardEntries.sort((a, b) {
      if (b.score != a.score) return b.score.compareTo(a.score);
      return b.wins.compareTo(a.wins);
    });
    _storeLeaderboard();

    if (cloudLeaderboardEnabled) {
      await _leaderboardService.saveCloudEntry(name, tag, playerScore, 1);
      await _loadCloudLeaderboard();
    }

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    return Scaffold(
      backgroundColor: backgroundColor,
      floatingActionButton: FloatingActionButton(
        onPressed: _showLeaderboardDialog,
        backgroundColor: accentGold,
        foregroundColor: Colors.black,
        child: const Icon(Icons.leaderboard),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _buildHeader(isMobile),
                Expanded(
                  child: Center(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        double size = constraints.maxWidth < 600
                            ? constraints.maxWidth * 0.95
                            : 550;
                        double boardSize = size < constraints.maxHeight * 0.85
                            ? size
                            : constraints.maxHeight * 0.85;

                        return SizedBox(
                          width: boardSize,
                          height: boardSize,
                          child: GridView.builder(
                            itemCount: 8 * 8,
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
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
                _buildFooter(isMobile),
              ],
            ),
            if (showCoinBurst) _buildCoinAnimation(),
          ],
        ),
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
            const Text('Top Learners',
                style:
                    TextStyle(color: accentGold, fontWeight: FontWeight.bold)),
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
                const Text('Global Leaderboard',
                    style: TextStyle(
                        color: accentGold, fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                if (isLoadingCloudLeaderboard)
                  const CircularProgressIndicator(color: accentGold)
                else if (cloudLeaderboardEntries.isEmpty)
                  Text(cloudStatusMessage,
                      style: const TextStyle(color: Colors.white54))
                else
                  Column(
                    children: [
                      ...cloudLeaderboardEntries
                          .take(10)
                          .toList()
                          .asMap()
                          .entries
                          .map((entry) {
                        final index = entry.key + 1;
                        final data = entry.value;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6.0),
                          child: Row(
                            children: [
                              Text('#$index',
                                  style: const TextStyle(
                                      color: accentGold,
                                      fontWeight: FontWeight.bold)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(data.name,
                                        style: const TextStyle(color: Colors.white),
                                        overflow: TextOverflow.ellipsis),
                                    if (data.schoolTag.isNotEmpty)
                                      Text(data.schoolTag,
                                          style: const TextStyle(
                                              color: accentGold,
                                              fontSize: 11),
                                          overflow: TextOverflow.ellipsis),
                                  ],
                                ),
                              ),
                              Text('${data.score}pts',
                                  style: const TextStyle(color: Colors.white70)),
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
              const Text('Local Leaderboard',
                  style: TextStyle(
                      color: accentGold, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              if (leaderboardEntries.isEmpty)
                const Text('No local entries yet.',
                    style: TextStyle(color: Colors.white54))
              else
                Column(
                  children: [
                    ...leaderboardEntries
                        .take(10)
                        .toList()
                        .asMap()
                        .entries
                        .map((entry) {
                      final index = entry.key + 1;
                      final data = entry.value;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6.0),
                        child: Row(
                          children: [
                            Text('#$index',
                                style: const TextStyle(
                                    color: accentGold,
                                    fontWeight: FontWeight.bold)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(data.name,
                                      style: const TextStyle(color: Colors.white),
                                      overflow: TextOverflow.ellipsis),
                                  if (data.schoolTag.isNotEmpty)
                                    Text(data.schoolTag,
                                        style: const TextStyle(
                                            color: accentGold,
                                            fontSize: 11),
                                        overflow: TextOverflow.ellipsis),
                                ],
                              ),
                            ),
                            Text('${data.score}pts',
                                style: const TextStyle(color: Colors.white70)),
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
                style: const TextStyle(
                    color: accentGold, fontWeight: FontWeight.bold),
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

  Widget _buildHeader(bool isMobile) {
    final turnColor = isPlayerTurn ? playerColor : aiColor;
    return Container(
      padding: isMobile
          ? const EdgeInsets.fromLTRB(12, 12, 12, 12)
          : const EdgeInsets.fromLTRB(24, 40, 24, 20),
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
      child: isMobile ? _buildMobileHeader() : _buildDesktopHeader(),
    );
  }

  Widget _buildDesktopHeader() {
    return Row(
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
            Row(
              children: [
                _buildMetricChip('Level', currentLevel.toString(), accentGold),
                const SizedBox(width: 10),
                Container(
                  key: scoreKey,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: accentGold.withAlpha(46),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.monetization_on,
                        color: Color(0xFFFCD116),
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        coinBalance.toString(),
                        style: TextStyle(
                          color: accentGold.withAlpha(242),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _buildMetricChip('Score', playerScore.toString(), accentGold),
                const SizedBox(width: 10),
                _buildMetricChip(
                    'Orbs', wisdomOrbs.toString(), accentGold.withAlpha(217)),
              ],
            ),
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              isPlayerTurn ? 'PLAYER TURN' : 'AI TURN',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold),
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
    );
  }

  Widget _buildMobileHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'WISDOM DRAFT',
                  style: GoogleFonts.philosopher(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'GES Art Studio',
                  style: TextStyle(color: Colors.white70, fontSize: 10),
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  isPlayerTurn ? 'PLAYER' : 'AI',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                SizedBox(
                  width: 90,
                  child: Text(
                    isAskingQuestion
                        ? 'Answer in $timeRemaining s'
                        : statusText,
                    style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 9,
                        overflow: TextOverflow.ellipsis),
                    maxLines: 1,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _buildMetricChip('L', currentLevel.toString(), accentGold,
                compact: true),
            Container(
              key: scoreKey,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: accentGold.withAlpha(46),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.monetization_on,
                    color: Color(0xFFFCD116),
                    size: 12,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    coinBalance.toString(),
                    style: TextStyle(
                      color: accentGold.withAlpha(242),
                      fontWeight: FontWeight.bold,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            _buildMetricChip('Score', playerScore.toString(), accentGold,
                compact: true),
            _buildMetricChip(
                'Orbs', wisdomOrbs.toString(), accentGold.withAlpha(217),
                compact: true),
          ],
        ),
      ],
    );
  }

  Widget _buildMetricChip(String label, String value, Color color,
      {bool compact = false}) {
    if (compact) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: color.withAlpha(46),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                  color: color.withAlpha(242),
                  fontWeight: FontWeight.bold,
                  fontSize: 9),
            ),
            Text(value,
                style: TextStyle(
                    color: color.withAlpha(242),
                    fontWeight: FontWeight.bold,
                    fontSize: 10)),
          ],
        ),
      );
    }
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
            style: TextStyle(
                color: color.withAlpha(242), fontWeight: FontWeight.bold),
          ),
          Text(value,
              style: TextStyle(
                  color: color.withAlpha(242), fontWeight: FontWeight.bold)),
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
    final validMoves =
        selectedPiece != null ? _possibleMoves(selectedPiece!) : [];
    final isPossibleMove =
        validMoves.any((move) => move['row'] == row && move['col'] == col);
    final isCaptureDestination = selectedPiece != null &&
        isPossibleMove &&
        _isCaptureMove(selectedPiece!, row, col);
    final tileColor = (row + col) % 2 == 1 ? darkTileColor : lightTileColor;
    final pieceColor = piece?.isPlayer == true ? playerColor : aiColor;

    return GestureDetector(
      onTap: () => _handleCellTap(row, col),
      onTapDown: (_) {
        // Immediate visual feedback
        setState(() {});
      },
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
                          color: isSelected
                              ? accentGold.withAlpha(191)
                              : Colors.black.withAlpha(77),
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

  Widget _buildFooter(bool isMobile) {
    final playerCount = pieces.where((piece) => piece.isPlayer).length;
    final aiCount = pieces.where((piece) => !piece.isPlayer).length;

    return Container(
      width: double.infinity,
      padding: isMobile
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
          : const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              isMobile
                  ? _miniStat('P', '$playerCount', compact: true)
                  : _miniStat('Player', '$playerCount'),
              isMobile
                  ? _miniStat('AI', '$aiCount', compact: true)
                  : _miniStat('AI', '$aiCount'),
              isMobile
                  ? _miniStat('S', '$currentStreak', compact: true)
                  : _miniStat('Streak', '$currentStreak'),
              isMobile
                  ? IconButton(
                      onPressed: _initializeBoard,
                      icon: const Icon(Icons.refresh),
                      color: accentGold,
                      iconSize: 20,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 36, minHeight: 36),
                    )
                  : ElevatedButton.icon(
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
          if (!isMobile) const SizedBox(height: 8),
          if (!isMobile)
            const Text(
              'Powered by TeamGrok',
              style: TextStyle(fontSize: 10, color: Colors.white54),
            ),
        ],
      ),
    );
  }

  Widget _miniStat(String label, String value, {bool compact = false}) {
    if (compact) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 9, color: Colors.white70),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ],
      );
    }
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

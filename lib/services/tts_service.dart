import 'package:flutter_tts/flutter_tts.dart';
import '../config.dart';

enum TtsPriority { critical, high, medium, low }

class _TtsQueueItem {
  final String      text;
  final TtsPriority priority;
  final int         delayMs;
  _TtsQueueItem(this.text, this.priority, this.delayMs);
}

class TtsService {
  final FlutterTts _tts = FlutterTts();

  bool        _ready          = false;
  bool        _speaking       = false;
  TtsPriority? _currentPriority;
  String?     _lastText;
  DateTime    _lastSpoke = DateTime.fromMillisecondsSinceEpoch(0);

  // Stats
  int totalSpoken       = 0;
  int duplicatesSkipped = 0;
  int cooldownSkipped   = 0;
  int urgentSpoken      = 0;
  int interruptedCount  = 0;

  final List<_TtsQueueItem> _queue = [];

  Future<void> init() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.44);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    await _tts.awaitSpeakCompletion(false);

    _tts.setCompletionHandler(() {
      _speaking = false;
      _currentPriority = null;
      _processQueue();
    });

    _ready = true;
  }

  /// Speak with priority and cooldown logic.
  /// Will only interrupt what's currently playing if the new item
  /// genuinely outranks it (lower index = higher priority).
  Future<void> speak(
    String text, {
    TtsPriority priority = TtsPriority.medium,
  }) async {
    if (!_ready) await init();

    final now     = DateTime.now();
    final elapsed = now.difference(_lastSpoke).inMilliseconds;

    if (text == _lastText &&
        elapsed < AppConfig.ttsSameCueCooldownMs) {
      duplicatesSkipped++;
      return;
    }

    if (priority == TtsPriority.low || priority == TtsPriority.medium) {
      if (elapsed < AppConfig.ttsAnyCueCooldownMs) {
        cooldownSkipped++;
        return;
      }
    }

    // Only interrupt what's CURRENTLY SPEAKING if this new item
    // genuinely outranks it. Never interrupt critical/high with
    // anything other than critical.
    final outranksCurrent = _currentPriority == null ||
        priority.index < _currentPriority!.index;

    if (_speaking && !outranksCurrent) {
      // Don't interrupt — just queue it, dedupe queue by priority
      _queue.removeWhere((item) =>
          item.priority == TtsPriority.low ||
          item.priority == TtsPriority.medium);
      _queue.add(_TtsQueueItem(text, priority, 0));
      _queue.sort((a, b) => a.priority.index.compareTo(b.priority.index));
      return;
    }

    if (_speaking && outranksCurrent) {
      // Genuinely more important — interrupt, but only now
      interruptedCount++;
      _queue.clear();
      await _tts.stop();
      _speaking = false;
    }

    int delayMs = 0;
    switch (priority) {
      case TtsPriority.critical: delayMs = AppConfig.importanceHighMs;   break;
      case TtsPriority.high:     delayMs = AppConfig.importanceHighMs;   break;
      case TtsPriority.medium:   delayMs = AppConfig.importanceMediumMs; break;
      case TtsPriority.low:      delayMs = AppConfig.importanceLowMs;    break;
    }

    _queue.add(_TtsQueueItem(text, priority, delayMs));
    _queue.sort((a, b) => a.priority.index.compareTo(b.priority.index));

    if (!_speaking) _processQueue();
  }

  void _processQueue() async {
    if (_queue.isEmpty || _speaking) return;

    final item = _queue.removeAt(0);
    _speaking        = true;
    _currentPriority = item.priority;
    _lastText        = item.text;
    _lastSpoke       = DateTime.now();
    totalSpoken++;

    if (item.delayMs > 0) {
      await Future.delayed(Duration(milliseconds: item.delayMs));
    }

    await _tts.speak(item.text);
  }

  /// Speak immediately, interrupt everything. For STOP / safety only.
  /// Stays protected as 'critical' so nothing can cut it off afterward.
  Future<void> speakUrgent(String text) async {
    if (!_ready) await init();
    _queue.clear();
    urgentSpoken++;
    totalSpoken++;
    await _tts.stop();
    _speaking        = true;
    _currentPriority = TtsPriority.critical;
    await _tts.speak(text);
    _lastText  = text;
    _lastSpoke = DateTime.now();
  }

  Future<void> stop() async {
    _queue.clear();
    _speaking        = false;
    _currentPriority = null;
    await _tts.stop();
  }

  void dispose() {
    _queue.clear();
    _tts.stop();
  }

  Map<String, int> get stats => {
    'total_spoken':       totalSpoken,
    'duplicates_skipped': duplicatesSkipped,
    'cooldown_skipped':   cooldownSkipped,
    'urgent_spoken':      urgentSpoken,
    'interrupted':        interruptedCount,
  };
}


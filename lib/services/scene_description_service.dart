import 'dart:typed_data';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../models/sensor_data.dart';
import '../models/detection_result.dart';

/// SceneDescriptionService provides rich ambient awareness descriptions.
/// Unlike the cascade pipeline which describes obstacles, this service
/// describes the WHOLE SCENE in natural language.
///
/// Examples of output:
/// "You appear to be in a busy shopping centre. There are several people
///  moving in different directions ahead of you. A shop entrance is on
///  your left about three metres away."
///
/// "You are in a quiet office corridor. A person is walking away from
///  you about four metres ahead. The path is clear on both sides."
///
/// Triggered by 6 smart parameters — never called every frame.

class SceneDescriptionService {

  // ── Cooldown tracking ─────────────────────────────────────────────────
  DateTime _lastAnyDescription   = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastProximityTrigger = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastAmbiguousTrigger = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastInconsistency    = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastStationary       = DateTime.fromMillisecondsSinceEpoch(0);

  // ── Rolling state ─────────────────────────────────────────────────────
  final List<bool>   _gateHistory     = [];   // last 4 gate results
  final List<double> _centerHistory   = [];   // last 8 center readings
  final List<double> _leftHistory     = [];
  final List<double> _rightHistory    = [];
  final List<String> _crowdingHistory = [];   // last 3 crowding readings

  // ── Output ────────────────────────────────────────────────────────────
  String _lastDescription = '';
  String _lastTrigger     = '';
  bool   _isLoading       = false;

  // ── Counters ──────────────────────────────────────────────────────────
  int totalCalls         = 0;
  int proximityCount     = 0;
  int ambiguousCount     = 0;
  int inconsistencyCount = 0;
  int stationaryCount    = 0;
  int periodicCount      = 0;
  int crowdedCount       = 0;

  // ── Settings (adjustable) ─────────────────────────────────────────────
  double proximityThreshold = 120.0;  // cm
  int    periodicSeconds    = 20;     // seconds between periodic calls

  String get lastDescription => _lastDescription;
  String get lastTrigger     => _lastTrigger;
  bool   get isLoading       => _isLoading;

  // THE SCENE DESCRIPTION PROMPT
  // Much richer than the navigation prompt — describes the whole scene
  static const String _scenePrompt = '''
You are describing an environment to a blind person who is navigating
on foot with a chest-mounted camera. Give them a complete picture of
their surroundings so they understand where they are and what is around
them.

Respond in 2-3 natural spoken sentences. Write as if you are calmly
speaking to the person directly.

Include:
- What type of space this appears to be (shop, corridor, street, office,
  home, restaurant, station, etc.)
- How busy or crowded it is and what people are doing
- Key landmarks or features that help with orientation (doors, counters,
  walls, turns, exits visible)
- Any hazards or things requiring attention beyond the immediate obstacle
- The general feel of the space (open, narrow, busy, quiet)

Do NOT:
- Mention colours unless critical for navigation
- Use technical language
- Start with "I can see" or "The image shows"
- Describe decorations or irrelevant details
- Be longer than 3 sentences

Write as natural spoken English — this will be read aloud by a text
to speech engine.

Examples of GOOD responses:

"You appear to be in a busy supermarket aisle. There are several
 shoppers moving around you and a row of shelves on both sides.
 The aisle appears to open up ahead into a wider area."

"You are in an office with several desks and people working. The
 space is moderately busy with people walking between workstations.
 There appears to be an open area ahead and a glass wall on your right."

"You seem to be on a busy pavement outside. People are walking in
 both directions and there is a shop entrance on your left about
 two metres ahead. The path ahead appears clear for several metres."

"You are in a quiet hospital corridor. The path ahead is clear and
 wide. There appears to be a reception desk or nurses station about
 five metres ahead on the right."
''';

  /// Check all 6 trigger parameters every frame.
  /// Returns trigger reason string, or null if no description needed.
  String? checkTriggers({
    required SensorData       sensors,
    required GateResult?      lastGate,
    required DetectionResult? lastDetection,
  }) {
    _updateState(sensors, lastGate, lastDetection);
    final now = DateTime.now();

    // Minimum 4 seconds between ANY description calls
    if (now.difference(_lastAnyDescription).inSeconds < 4) return null;

    // ── TRIGGER 1: PROXIMITY ───────────────────────────────────────────
    // Something is close — describe full scene for context
    // Cooldown: 10 seconds
    if (sensors.center < proximityThreshold &&
        now.difference(_lastProximityTrigger).inSeconds >= 10) {
      return 'proximity';
    }

    // ── TRIGGER 2: AMBIGUOUS GATE ───────────────────────────────────────
    // Gate confidence between 0.35-0.65 — AI is uncertain
    // A full scene description helps clarify the situation
    // Cooldown: 8 seconds
    final gateConf = lastGate?.confidence ?? 1.0;
    if (gateConf >= 0.35 && gateConf <= 0.65 &&
        now.difference(_lastAmbiguousTrigger).inSeconds >= 8) {
      return 'ambiguous';
    }

    // ── TRIGGER 3: DETECTION INCONSISTENCY ───────────────────────────────
    // Gate keeps changing YES/NO/YES/NO — scene is confusing
    // Cooldown: 12 seconds
    if (_gateHistory.length >= 4 &&
        now.difference(_lastInconsistency).inSeconds >= 12) {
      int switches = 0;
      for (int i = 1; i < _gateHistory.length; i++) {
        if (_gateHistory[i] != _gateHistory[i - 1]) switches++;
      }
      if (switches >= 3) return 'inconsistency';
    }

    // ── TRIGGER 4: STATIONARY ────────────────────────────────────────────
    // User hasn't moved in a while — may be lost or confused
    // Cooldown: 15 seconds
    if (_centerHistory.length >= 4 &&
        now.difference(_lastStationary).inSeconds >= 15) {
      final cVar = _variance(_centerHistory);
      final lVar = _variance(_leftHistory);
      final rVar = _variance(_rightHistory);
      if (cVar < 25.0 && lVar < 25.0 && rVar < 25.0) {
        return 'stationary';
      }
    }

    // ── TRIGGER 5: CROWDED ────────────────────────────────────────────────
    // Gemini keeps detecting groups or multiple people
    // Cooldown: 15 seconds
    if (_crowdingHistory.length >= 3 &&
        now.difference(_lastAnyDescription).inSeconds >= 15) {
      final recentCrowded = _crowdingHistory
          .where((c) => c == 'crowded' || c == 'moderate')
          .length;
      if (recentCrowded >= 2) return 'crowded';
    }

    // ── TRIGGER 6: PERIODIC ───────────────────────────────────────────────
    // Regular ambient update when path is clear
    // Cooldown: periodicSeconds (default 20)
    final allClear = sensors.center > 150 &&
                     sensors.left   > 120 &&
                     sensors.right  > 120;
    if (allClear &&
        now.difference(_lastAnyDescription).inSeconds >= periodicSeconds) {
      return 'periodic';
    }

    return null;
  }

  /// Call Gemini for a full scene description.
  /// Fire-and-forget from cascade_engine — never blocks navigation cue.
  Future<String?> describe(
      Uint8List imageBytes, String triggerReason) async {
    if (!AppConfig.isApiKeySet) return null;

    _isLoading   = true;
    _lastTrigger = triggerReason;

    try {
      final response = await http.post(
        Uri.parse(
          '${AppConfig.geminiEndpoint}?key=${AppConfig.geminiApiKey}'
        ),
        headers: {'Content-Type': 'application/json; charset=UTF-8'},
        body: jsonEncode({
          'contents': [{
            'parts': [
              {'text': _scenePrompt},
              {
                'inline_data': {
                  'mime_type': 'image/jpeg',
                  'data':      base64Encode(imageBytes),
                }
              }
            ]
          }],
          'generationConfig': {
            'temperature':     0.3,
            'maxOutputTokens': 150,
            'topP':            0.9,
          },
        }),
      ).timeout(const Duration(seconds: 7));

      _isLoading = false;

      if (response.statusCode != 200) return null;

      final json       = jsonDecode(response.body) as Map<String, dynamic>;
      final candidates = json['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) return null;

      final text = (candidates[0]['content']['parts'][0]['text'] as String)
          .trim();

      _lastDescription    = text;
      _lastAnyDescription = DateTime.now();
      totalCalls++;
      _updateCooldown(triggerReason);

      return text;

    } catch (e) {
      _isLoading = false;
      print('[scene] describe() error: $e');
      return null;
    }
  }

  void _updateState(
      SensorData s, GateResult? g, DetectionResult? d) {
    // Update rolling sensor history
    _centerHistory.add(s.center);
    _leftHistory.add(s.left);
    _rightHistory.add(s.right);
    if (_centerHistory.length > 8) {
      _centerHistory.removeAt(0);
      _leftHistory.removeAt(0);
      _rightHistory.removeAt(0);
    }

    // Update gate history
    if (g != null) {
      _gateHistory.add(g.obstacleDetected);
      if (_gateHistory.length > 4) _gateHistory.removeAt(0);
    }

    // Update crowding history from Gemini detections
    if (d != null && d.success) {
      _crowdingHistory.add(d.environment.crowding);
      if (_crowdingHistory.length > 3) _crowdingHistory.removeAt(0);
    }
  }

  void _updateCooldown(String reason) {
    final now = DateTime.now();
    switch (reason) {
      case 'proximity':
        _lastProximityTrigger = now;
        proximityCount++;
        break;
      case 'ambiguous':
        _lastAmbiguousTrigger = now;
        ambiguousCount++;
        break;
      case 'inconsistency':
        _lastInconsistency = now;
        inconsistencyCount++;
        break;
      case 'stationary':
        _lastStationary = now;
        stationaryCount++;
        break;
      case 'crowded':
        crowdedCount++;
        break;
      case 'periodic':
        periodicCount++;
        break;
    }
  }

  double _variance(List<double> v) {
    if (v.length < 2) return 0;
    final mean = v.reduce((a, b) => a + b) / v.length;
    return v.map((x) => (x - mean) * (x - mean))
            .reduce((a, b) => a + b) / v.length;
  }

  String triggerLabel(String reason) {
    const labels = {
      'proximity':     'Obstacle approaching',
      'ambiguous':     'Unclear detection',
      'inconsistency': 'Scene confusion',
      'stationary':    'You stopped',
      'crowded':       'Crowded environment',
      'periodic':      'Ambient awareness',
    };
    return labels[reason] ?? reason;
  }

  Map<String, dynamic> toStats() => {
    'total_scene_calls':      totalCalls,
    'proximity_triggers':     proximityCount,
    'ambiguous_triggers':     ambiguousCount,
    'inconsistency_triggers': inconsistencyCount,
    'stationary_triggers':    stationaryCount,
    'crowded_triggers':       crowdedCount,
    'periodic_triggers':      periodicCount,
  };
}



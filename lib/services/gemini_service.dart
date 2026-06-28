import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../models/sensor_data.dart';
import '../models/detection_result.dart';

class GeminiService {

  static String _gatePrompt(SensorData sensors) => '''
You are the first stage of a navigation system for a blind person.
You have two sources of information: this camera image showing what is
ahead, and live ultrasonic distance sensor readings taken at the exact
same moment.

Ultrasonic sensor readings right now:
Left: ${sensors.left.round()}cm
Center: ${sensors.center.round()}cm
Right: ${sensors.right.round()}cm

Use both together. The sensor readings are precise ground-truth distance
measurements — trust them over any visual distance impression. The image
tells you WHAT is there; the sensors tell you exactly HOW FAR.

Answer ONE question: is there anything this person needs to know about
to navigate safely?

Answer ONLY with this exact JSON, nothing else:
{"obstacle_detected": true, "confidence": 0.85}

obstacle_detected is TRUE if you see ANY of:
- A person, animal, or moving object
- Furniture (chair, table, sofa, desk)
- A door (open or closed)
- Stairs going up or down
- A wall, pillar, or barrier closer than 3 metres
- A step, kerb, or elevation change
- A narrow passage or corridor
- Wet floor, hazard, or obstruction
- A vehicle
- Any sensor reading under 150cm, even if the image is unclear about what
  is causing it — treat a close sensor reading as evidence something is
  there even if you cannot visually confirm what it is

obstacle_detected is FALSE only if:
- The path ahead is completely clear for at least 3 metres
- All three sensor readings are above 150cm
- There is nothing a walking person could collide with

confidence: your certainty 0.0 to 1.0
No markdown. No explanation. Only the JSON.
''';

  static String _classifyPrompt(SensorData sensors) => '''
You are a navigation assistant for a blind person walking with a
chest-mounted camera. You have two sources of information that you must
fuse together into one coherent understanding of the room:

1. This camera image — shows what objects are present and what they are
2. Live ultrasonic sensor readings taken at the exact same moment:
   Left: ${sensors.left.round()}cm
   Center: ${sensors.center.round()}cm
   Right: ${sensors.right.round()}cm

CRITICAL RULE ON DISTANCE: the ultrasonic readings above are precise
ground-truth measurements. Always prefer them over your own visual
distance estimate. Use the image to identify what the object actually
is and confirm its position (left/center/right), but report distance
based on the sensor reading for that direction, not on how far the
object visually appears to be.

If the sensor on a side is close (under 150cm) but you cannot clearly
identify what is causing it from the image, still report it using the
sensor distance, with type UNKNOWN and a specifics field describing
the uncertainty (e.g. "something detected on the left, not clearly
visible in frame").

If the image and a sensor reading clearly conflict (e.g. the image
shows nothing nearby on the left but the left sensor reads 30cm),
trust the sensor and mention this discrepancy briefly in
navigation_instruction, since the sensor may be detecting something
outside the camera's field of view.

Analyze with extreme care. Respond ONLY with this exact JSON structure,
nothing else, no markdown:
{
  "primary_obstacle": {
    "type": "PERSON",
    "specifics": "elderly woman with walking stick",
    "position": "center",
    "distance_cm": 85,
    "distance_estimate": "very close",
    "moving": true,
    "moving_direction": "toward you"
  },
  "secondary_obstacles": [
    {
      "type": "CHAIR",
      "position": "right",
      "distance_cm": 140,
      "distance_estimate": "nearby"
    }
  ],
  "environment": {
    "setting": "indoor corridor",
    "crowding": "low",
    "lighting": "good",
    "floor_hazards": false,
    "narrow_passage": false
  },
  "navigation_instruction": "Stop and wait. A person is walking directly toward you, about 85 centimetres ahead. Once they pass, proceed forward.",
  "urgency": "high",
  "confidence": 0.88,
  "uncertainty_reason": ""
}

RULES FOR EACH FIELD:

primary_obstacle.type — must be one of:
PERSON, GROUP_OF_PEOPLE, CHILD, ANIMAL, CHAIR, TABLE, SOFA,
DESK, BED, DOOR_OPEN, DOOR_CLOSED, STAIRS_UP, STAIRS_DOWN,
STEP_UP, STEP_DOWN, WALL, PILLAR, GLASS_DOOR, VEHICLE,
BICYCLE, SHOPPING_CART, TROLLEY, WET_FLOOR, NARROW_PASSAGE,
COUNTER, SHELF, CLEAR, UNKNOWN

primary_obstacle.specifics — describe exactly what you see in
plain English, 3-8 words. Examples:
  "man carrying large boxes"
  "glass door partially open"
  "steep staircase going down"
  "group of children running"
  "shopping trolley blocking path"
  "something detected on the left, not clearly visible"

primary_obstacle.position — left, center, or right
  Match this to whichever sensor reading is closest, unless the image
  clearly shows the object is in a different position than the closest
  sensor would suggest.

primary_obstacle.distance_cm — the actual sensor reading in centimetres
  for whichever direction (left/center/right) this obstacle is in.
  Use the exact number from the sensor data provided above. This must
  be a plain integer, not a range or estimate.

primary_obstacle.distance_estimate — one of, chosen based on distance_cm:
  "very close" (under 60cm)
  "close" (60-120cm)
  "nearby" (120-250cm)
  "ahead" (250-400cm)
  "far" (over 400cm)

primary_obstacle.moving — true if the obstacle is a person or
animal that appears to be moving

primary_obstacle.moving_direction — only if moving is true:
  "toward you", "away from you", "crossing left to right",
  "crossing right to left", "stationary"

secondary_obstacles — list any OTHER obstacles visible in the
scene that could affect navigation, each with its own distance_cm
taken from the sensor in that direction. Can be empty list [].

environment.setting — describe the space in 2-3 words

environment.crowding — one of: "empty", "low", "moderate", "crowded"

environment.lighting — one of: "dark", "dim", "adequate", "good", "bright"

environment.floor_hazards — true if you see wet floors, steps,
uneven surfaces, cables, or anything the person could trip on

environment.narrow_passage — true if the path ahead is less than
1 metre wide, or if left and right sensors both read under 100cm

navigation_instruction — THIS IS THE MOST IMPORTANT FIELD.
Write a clear, natural, complete spoken instruction for a blind
person. Be specific. Use the actual object you identified and the
exact sensor distance in centimetres, not a vague visual guess.
Do NOT say "obstacle" — say what it actually is.
Do NOT say just "move left" — explain WHY and by how much.

Good examples:
  "A person is walking toward you from the center, about 90
   centimetres away. Stop and wait two seconds for them to pass."

  "There are stairs going down directly ahead, about 200 centimetres
   away based on the sensor. Approach slowly and find the handrail."

  "A chair is blocking the center path, 75 centimetres ahead. Step to
   your left to go around it."

Bad examples (never do this):
  "Obstacle ahead, move left." ← too vague
  "Person detected." ← no instruction
  "Move right." ← no context, ignores sensor distance

urgency — one of: "low", "medium", "high", "critical"
  critical: immediate danger (stairs, sensor under 40cm, very close
            moving person)
  high: action needed soon (person approaching, door, step, sensor
        under 100cm)
  medium: awareness needed (furniture nearby, narrow passage)
  low: informational (something in periphery, not blocking path)

confidence: 0.0 to 1.0

uncertainty_reason: if confidence < 0.6, briefly explain why.
Otherwise empty string "".
''';

  /// Stage 1: Is there an obstacle? Fast binary check.
  /// Now fuses sensor readings with the image.
  /// Never throws. Returns safe fallback (obstacle=true) on any error.
  Future<GateResult> runGate(Uint8List imageBytes, SensorData sensors) async {
    final sw = Stopwatch()..start();
    try {
      final raw  = await _callApi(_gatePrompt(sensors), imageBytes);
      sw.stop();
      final json = _cleanAndParse(raw);
      return GateResult(
        obstacleDetected: json['obstacle_detected'] as bool? ?? true,
        confidence:       ((json['confidence'] as num?) ?? 0.5).toDouble(),
        latencyMs:        sw.elapsedMilliseconds,
      );
    } catch (e) {
      sw.stop();
      print('[gemini] Gate error: $e');
      return GateResult.error();
    }
  }

  /// Stage 2: What is it, where is it, what should the user do?
  /// Now fuses sensor readings with the image for accurate distance
  /// and grounded object identification.
  /// Never throws. Returns fallback on any error.
  Future<DetectionResult> classify(
      Uint8List imageBytes, SensorData sensors) async {
    final sw = Stopwatch()..start();
    try {
      final raw  = await _callApi(_classifyPrompt(sensors), imageBytes);
      sw.stop();
      final json = _cleanAndParse(raw);

      final primary = json['primary_obstacle'] as Map<String, dynamic>? ?? {};
      final label   = _parseLabel(primary['type'] as String? ?? 'UNKNOWN');
      final pos     = _parsePosition(primary['position'] as String? ?? 'unclear');

      final secondaryList = json['secondary_obstacles'] as List? ?? [];
      final secondaries   = secondaryList.map((s) {
        final m = s as Map<String, dynamic>;
        return SecondaryObstacle(
          type:             m['type']              as String? ?? 'UNKNOWN',
          position:         m['position']          as String? ?? 'unclear',
          distanceEstimate: m['distance_estimate'] as String? ?? 'nearby',
        );
      }).toList();

      final env     = json['environment'] as Map<String, dynamic>? ?? {};
      final envInfo = EnvironmentInfo(
        setting:       env['setting']        as String? ?? 'unknown',
        crowding:      env['crowding']       as String? ?? 'unknown',
        lighting:      env['lighting']       as String? ?? 'unknown',
        floorHazards:  env['floor_hazards']  as bool?   ?? false,
        narrowPassage: env['narrow_passage'] as bool?   ?? false,
      );

      // Sensor-grounded distance: prefer the model's reported distance_cm
      // (which it was told to copy from the sensor reading), falling back
      // to the raw sensor value for that position if missing.
      final reportedDistanceCm = (primary['distance_cm'] as num?)?.round();
      final fallbackDistanceCm = _sensorDistanceForPosition(pos, sensors);
      final groundedDistanceCm = reportedDistanceCm ?? fallbackDistanceCm;

      return DetectionResult(
        label:                 label,
        specifics:             primary['specifics']           as String? ?? '',
        position:              pos,
        distanceEstimate:      primary['distance_estimate']   as String? ?? 'nearby',
        isMoving:              primary['moving']              as bool?   ?? false,
        movingDirection:       primary['moving_direction']    as String? ?? '',
        secondaryObstacles:    secondaries,
        environment:           envInfo,
        navigationInstruction: json['navigation_instruction'] as String? ?? '',
        urgency:               json['urgency']                as String? ?? 'medium',
        confidence:            ((json['confidence'] as num?) ?? 0.0)
                                   .toDouble().clamp(0.0, 1.0),
        uncertaintyReason:     json['uncertainty_reason']     as String? ?? '',
        latencyMs:             sw.elapsedMilliseconds,
        success:               true,
        rawResponse:           raw,
        distanceCm:            groundedDistanceCm,
      );

    } catch (e) {
      sw.stop();
      print('[gemini] Classify error: $e');
      return DetectionResult.fallback(e.toString().substring(
          0, e.toString().length.clamp(0, 80)));
    }
  }

  /// Picks the matching sensor reading for a given position, used as a
  /// fallback if Gemini doesn't return distance_cm.
  int _sensorDistanceForPosition(ObstaclePosition pos, SensorData sensors) {
    switch (pos) {
      case ObstaclePosition.left:   return sensors.left.round();
      case ObstaclePosition.right:  return sensors.right.round();
      case ObstaclePosition.center: return sensors.center.round();
      case ObstaclePosition.unclear: return sensors.center.round();
    }
  }

  /// Make HTTP POST to Gemini API with image and prompt.
  Future<String> _callApi(String prompt, Uint8List imageBytes) async {
    if (!AppConfig.isApiKeySet) {
      throw Exception('Gemini API key not set');
    }

    final body = jsonEncode({
      'contents': [{
        'parts': [
          {'text': prompt},
          {
            'inline_data': {
              'mime_type': 'image/jpeg',
              'data':      base64Encode(imageBytes),
            }
          }
        ]
      }],
      'generationConfig': {
        'temperature':     0.1,
        'maxOutputTokens': 280,
        'topP':            0.8,
      },
      'safetySettings': [
        {
          'category':  'HARM_CATEGORY_DANGEROUS_CONTENT',
          'threshold': 'BLOCK_NONE',
        }
      ],
    });

    final response = await http.post(
      Uri.parse('${AppConfig.geminiEndpoint}?key=${AppConfig.geminiApiKey}'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body:    body,
    ).timeout(Duration(seconds: AppConfig.geminiTimeoutSecs));

    if (response.statusCode != 200) {
      throw Exception(
        'HTTP ${response.statusCode}: '
        '${response.body.substring(0, response.body.length.clamp(0, 200))}'
      );
    }

    final respJson   = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = respJson['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) {
      throw Exception('No candidates in response');
    }
    final parts = (candidates[0]['content']['parts'] as List);
    return (parts[0]['text'] as String).trim();
  }

  /// Strip markdown fences and parse JSON.
  Map<String, dynamic> _cleanAndParse(String raw) {
    var clean = raw.trim();
    if (clean.startsWith('```')) {
      clean = clean
          .replaceAll(RegExp(r'^```json\s*', multiLine: true), '')
          .replaceAll(RegExp(r'^```\s*',      multiLine: true), '')
          .trim();
    }
    return jsonDecode(clean) as Map<String, dynamic>;
  }

  ObstacleLabel _parseLabel(String raw) {
    switch (raw.toUpperCase().trim()) {
      case 'PERSON':          return ObstacleLabel.person;
      case 'GROUP_OF_PEOPLE': return ObstacleLabel.group_of_people;
      case 'CHILD':           return ObstacleLabel.child;
      case 'ANIMAL':          return ObstacleLabel.animal;
      case 'CHAIR':           return ObstacleLabel.chair;
      case 'TABLE':           return ObstacleLabel.table;
      case 'SOFA':            return ObstacleLabel.sofa;
      case 'DESK':            return ObstacleLabel.desk;
      case 'BED':             return ObstacleLabel.bed;
      case 'DOOR_OPEN':       return ObstacleLabel.door_open;
      case 'DOOR_CLOSED':     return ObstacleLabel.door_closed;
      case 'STAIRS_UP':       return ObstacleLabel.stairs_up;
      case 'STAIRS_DOWN':     return ObstacleLabel.stairs_down;
      case 'STEP_UP':         return ObstacleLabel.step_up;
      case 'STEP_DOWN':       return ObstacleLabel.step_down;
      case 'WALL':            return ObstacleLabel.wall;
      case 'PILLAR':          return ObstacleLabel.pillar;
      case 'GLASS_DOOR':      return ObstacleLabel.glass_door;
      case 'VEHICLE':         return ObstacleLabel.vehicle;
      case 'BICYCLE':         return ObstacleLabel.bicycle;
      case 'SHOPPING_CART':   return ObstacleLabel.shopping_cart;
      case 'TROLLEY':         return ObstacleLabel.trolley;
      case 'WET_FLOOR':       return ObstacleLabel.wet_floor;
      case 'NARROW_PASSAGE':  return ObstacleLabel.narrow_passage;
      case 'COUNTER':         return ObstacleLabel.counter;
      case 'SHELF':           return ObstacleLabel.shelf;
      case 'CLEAR':           return ObstacleLabel.clear;
      default:                return ObstacleLabel.unknown;
    }
  }

  ObstaclePosition _parsePosition(String raw) {
    switch (raw.toLowerCase().trim()) {
      case 'left':   return ObstaclePosition.left;
      case 'center': return ObstaclePosition.center;
      case 'right':  return ObstaclePosition.right;
      default:       return ObstaclePosition.unclear;
    }
  }
}

/// Result from Stage 2 full classification call
class DetectionResult {
  // Primary obstacle
  final ObstacleLabel    label;
  final String           specifics;          // e.g. "elderly woman with stick"
  final ObstaclePosition position;
  final String           distanceEstimate;   // "very close", "nearby", etc.
  final int?             distanceCm;         // sensor-grounded exact distance
  final bool             isMoving;
  final String           movingDirection;    // "toward you", "crossing", etc.

  // Secondary obstacles
  final List<SecondaryObstacle> secondaryObstacles;

  // Environment
  final EnvironmentInfo environment;

  // Navigation
  final String navigationInstruction;        // Full spoken instruction
  final String urgency;                      // "low"/"medium"/"high"/"critical"

  // Meta
  final double confidence;
  final String uncertaintyReason;
  final int    latencyMs;
  final bool   success;
  final String rawResponse;

  const DetectionResult({
    required this.label,
    required this.specifics,
    required this.position,
    required this.distanceEstimate,
    this.distanceCm,
    required this.isMoving,
    required this.movingDirection,
    required this.secondaryObstacles,
    required this.environment,
    required this.navigationInstruction,
    required this.urgency,
    required this.confidence,
    required this.uncertaintyReason,
    required this.latencyMs,
    required this.success,
    required this.rawResponse,
  });

  factory DetectionResult.fallback(String reason) => DetectionResult(
    label:                 ObstacleLabel.unknown,
    specifics:             '',
    position:              ObstaclePosition.unclear,
    distanceEstimate:      'unknown',
    distanceCm:            null,
    isMoving:              false,
    movingDirection:       '',
    secondaryObstacles:    const [],
    environment:           EnvironmentInfo.empty(),
    navigationInstruction: '',
    urgency:               'medium',
    confidence:            0.0,
    uncertaintyReason:     reason,
    latencyMs:             0,
    success:               false,
    rawResponse:           '',
  );

  String get labelDisplay =>
      label.name.replaceAll('_', ' ').toUpperCase();

  bool get isCritical => urgency == 'critical';
  bool get isHigh     => urgency == 'high' || urgency == 'critical';
}

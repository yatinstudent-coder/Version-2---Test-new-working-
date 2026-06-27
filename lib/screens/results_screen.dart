import 'package:flutter/material.dart';
import '../services/cascade_engine.dart';
import '../services/data_logger.dart';
import '../services/tts_service.dart';

class ResultsScreen extends StatefulWidget {
  const ResultsScreen({super.key});

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  CascadeEngine? _cascade;
  DataLogger? _logger;

  @override
  void initState() {
    super.initState();
    // In a real app, this would be passed from NavigationScreen
    // For now, we'll show empty stats
    _cascade = CascadeEngine(tts: TtsService());
    _logger = DataLogger();
  }

  @override
  Widget build(BuildContext context) {
    if (_cascade == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Session Results')),
        body: const Center(
          child: Text('No session data available'),
        ),
      );
    }

    final cascade = _cascade!;
    final total = cascade.totalFrames > 0 ? cascade.totalFrames : 1;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Session Results'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Header card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'API Efficiency Results',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'This is your science fair finding',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey.shade400,
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Big stat: API Calls Saved
          Card(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Text(
                    'API Calls Saved',
                    style: TextStyle(fontSize: 20),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '${cascade.apiSavingPercent.toStringAsFixed(0)}%',
                    style: const TextStyle(
                      fontSize: 64,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'of frames handled without calling Gemini',
                    style: TextStyle(fontSize: 16),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Stats grid
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Session Statistics',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  GridView.count(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisCount: 2,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    childAspectRatio: 2,
                    children: [
                      _statCard('Total Frames', cascade.totalFrames.toString()),
                      _statCard('Gate Calls', cascade.gateCalledCount.toString()),
                      _statCard('Gate Triggered', cascade.gateYesCount.toString()),
                      _statCard('Full AI Calls', cascade.classifyCount.toString()),
                      _statCard('Safety Fires', cascade.safetyCount.toString()),
                      _statCard('API Errors', cascade.apiErrorCount.toString()),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Bar chart
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Frame Handling Breakdown',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _barChart('Sensor only', cascade.sensorOnlyCount, total, Colors.grey),
                  const SizedBox(height: 8),
                  _barChart('Gate said clear', cascade.sensorOnlyCount - cascade.classifyCount, total, Colors.blue),
                  const SizedBox(height: 8),
                  _barChart('Full AI cascade', cascade.classifyCount, total, Colors.green),
                  const SizedBox(height: 8),
                  _barChart('Safety override', cascade.safetyCount, total, Colors.red),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Scene Description Stats Card
          Card(
            margin: const EdgeInsets.all(12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Scene Description Calls',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text(
                    'Gemini was called for a full scene description when:',
                    style: TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  _statRow('Proximity (<120cm)', cascade.sceneDescService.toStats()['proximity_triggers']),
                  _statRow('Ambiguous gate (0.35-0.65)', cascade.sceneDescService.toStats()['ambiguous_triggers']),
                  _statRow('Inconsistent detections', cascade.sceneDescService.toStats()['inconsistency_triggers']),

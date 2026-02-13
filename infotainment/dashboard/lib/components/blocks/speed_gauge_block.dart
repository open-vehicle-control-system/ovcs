import 'package:flutter/material.dart';
import 'package:gauge_indicator/gauge_indicator.dart';
import 'package:dashboard_flutter/models/block_config.dart';
import 'package:dashboard_flutter/services/metrics_service.dart';

/// Renders a radial speed gauge driven by a single metric.
/// Config options: unit (String), min (num), max (num).
class SpeedGaugeBlock extends StatelessWidget {
  final BlockConfig block;
  final MetricsService metricsService;

  const SpeedGaugeBlock({
    super.key,
    required this.block,
    required this.metricsService,
  });

  @override
  Widget build(BuildContext context) {
    final metric = block.metrics.first;
    final rawValue = metricsService.getValue(metric.module, metric.key);
    final currentSpeed = _toDouble(rawValue);
    final unit = block.config?['unit'] ?? 'km/h';
    final max = (block.config?['max'] as num?)?.toDouble() ?? 180;

    return AnimatedRadialGauge(
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeOutCubic,
      value: currentSpeed,
      axis: GaugeAxis(
        min: 0,
        max: max,
        degrees: 270,
        style: const GaugeAxisStyle(
          thickness: 30,
          background: Color(0xD9334155),
          segmentSpacing: 0,
        ),
        progressBar: GaugeProgressBar.basic(
          gradient: GaugeAxisGradient(
            colors: const [
              Color(0xFF8b5cf6),
              Color(0xFF7c3aed),
              Color(0xFF6d28d9),
              Color(0xFF5b21b6),
              Color(0xFF4c1d95),
            ],
            colorStops: const [0, 0.25, 0.5, 0.75, 1],
          ),
        ),
      ),
      builder: (context, child, value) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            value.toInt().toString(),
            style: const TextStyle(
              fontSize: 100,
              fontFamily: 'Lato',
              color: Colors.white,
              decoration: TextDecoration.none,
            ),
          ),
          Text(
            unit,
            style: const TextStyle(
              fontSize: 30,
              fontFamily: 'Lato',
              color: Colors.grey,
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }

  static double _toDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }
}

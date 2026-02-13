import 'package:flutter/material.dart';
import 'package:dashboard_flutter/models/block_config.dart';
import 'package:dashboard_flutter/services/metrics_service.dart';

/// Renders a grid of component status boxes driven by labeled metrics.
/// Each metric's label becomes the box title, and its value determines
/// the status color (OK/true = active, MISSING/false = dim, else = error).
class StatusGridBlock extends StatelessWidget {
  final BlockConfig block;
  final MetricsService metricsService;

  const StatusGridBlock({
    super.key,
    required this.block,
    required this.metricsService,
  });

  @override
  Widget build(BuildContext context) {
    final metrics = block.metrics;
    // Arrange into columns of 3
    const itemsPerColumn = 3;
    final columnCount = (metrics.length / itemsPerColumn).ceil();

    return Row(
      children: List.generate(columnCount, (colIdx) {
        final start = colIdx * itemsPerColumn;
        final end = (start + itemsPerColumn).clamp(0, metrics.length);
        final columnMetrics = metrics.sublist(start, end);

        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: columnMetrics.map((metric) {
            final value = metricsService.getValue(metric.module, metric.key);
            final label = metric.label ?? metric.key;
            final status = value?.toString() ?? 'MISSING';
            return _ComponentStatusBox(name: label, status: status);
          }).toList(),
        );
      }),
    );
  }
}

class _ComponentStatusBox extends StatelessWidget {
  final String name;
  final String status;

  const _ComponentStatusBox({required this.name, required this.status});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(7),
      width: 162,
      height: 64,
      decoration: _boxDecoration(),
      child: Center(
        child: Text(
          name,
          style: _textStyle(),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  BoxDecoration _boxDecoration() {
    return BoxDecoration(
      border: Border.all(color: _statusColor(), width: 2),
      borderRadius: BorderRadius.circular(10),
    );
  }

  TextStyle _textStyle() {
    return TextStyle(
      fontSize: 16,
      color: _statusColor(),
      decoration: TextDecoration.none,
      height: 1,
      fontFamily: 'Lato',
    );
  }

  Color _statusColor() {
    switch (status) {
      case 'MISSING':
      case 'false':
        return const Color.fromRGBO(238, 155, 117, 0.3);
      case 'OK':
      case 'true':
        return const Color.fromRGBO(238, 155, 117, 1);
      default:
        return const Color.fromRGBO(188, 48, 53, 1);
    }
  }
}

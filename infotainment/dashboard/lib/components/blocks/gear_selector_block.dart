import 'package:flutter/material.dart';
import 'package:dashboard_flutter/models/block_config.dart';
import 'package:dashboard_flutter/services/metrics_service.dart';
import 'package:dashboard_flutter/services/action_service.dart';

/// Renders a P/R/N/D gear selector with the active gear highlighted.
/// Uses the generic action system to request gear changes.
class GearSelectorBlock extends StatelessWidget {
  final BlockConfig block;
  final MetricsService metricsService;

  const GearSelectorBlock({
    super.key,
    required this.block,
    required this.metricsService,
  });

  void _requestGear(String gear) {
    if (block.actions.isNotEmpty) {
      final action = block.actions.first;
      ActionService.triggerAction(
        action.module,
        action.action,
        {'gear': gear},
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final metric = block.metrics.first;
    final currentGear = metricsService.getValue(metric.module, metric.key) as String? ?? 'parking';

    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _gearButton('P', 'parking', currentGear),
        _gearButton('R', 'reverse', currentGear),
        _gearButton('N', 'neutral', currentGear),
        _gearButton('D', 'drive', currentGear),
      ],
    );
  }

  Widget _gearButton(String label, String gearValue, String currentGear) {
    final isActive = currentGear == gearValue;
    return TextButton(
      onPressed: () => _requestGear(gearValue),
      style: TextButton.styleFrom(
        fixedSize: const Size(90, 110),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        backgroundColor: isActive
            ? const Color(0x40FFFFFF)
            : const Color(0x00FFFFFF),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 36,
          color: Colors.white,
          decoration: TextDecoration.none,
        ),
      ),
    );
  }
}

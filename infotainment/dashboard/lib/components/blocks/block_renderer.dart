import 'package:flutter/material.dart';
import 'package:dashboard_flutter/models/block_config.dart';
import 'package:dashboard_flutter/models/vehicle_config.dart';
import 'package:dashboard_flutter/services/metrics_service.dart';
import 'package:dashboard_flutter/components/blocks/speed_gauge_block.dart';
import 'package:dashboard_flutter/components/blocks/gear_selector_block.dart';
import 'package:dashboard_flutter/components/blocks/car_overview_block.dart';
import 'package:dashboard_flutter/components/blocks/battery_overview_block.dart';
import 'package:dashboard_flutter/components/blocks/status_grid_block.dart';
import 'package:dashboard_flutter/components/blocks/time_settings_block.dart';

/// Routes a [BlockConfig] to the appropriate block renderer widget
/// based on its `subtype`, and wraps it with the global block style.
class BlockRenderer extends StatelessWidget {
  final BlockConfig block;
  final MetricsService metricsService;
  final BlockStyle blockStyle;

  const BlockRenderer({
    super.key,
    required this.block,
    required this.metricsService,
    required this.blockStyle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.all(blockStyle.margin ?? 10),
      padding: EdgeInsets.all(blockStyle.padding ?? 20),
      decoration: BoxDecoration(
        color: _parseColor(blockStyle.backgroundColor) ?? const Color(0xD9111827),
        borderRadius: BorderRadius.circular(blockStyle.borderRadius ?? 30),
      ),
      child: _buildBlockContent(),
    );
  }

  Widget _buildBlockContent() {
    switch (block.subtype) {
      case 'speedGauge':
        return SpeedGaugeBlock(block: block, metricsService: metricsService);
      case 'gearSelector':
        return GearSelectorBlock(block: block, metricsService: metricsService);
      case 'carOverview':
        return CarOverviewBlock(block: block, metricsService: metricsService);
      case 'batteryOverview':
        return BatteryOverviewBlock(block: block, metricsService: metricsService);
      case 'statusGrid':
        return StatusGridBlock(block: block, metricsService: metricsService);
      case 'timeSettings':
        return TimeSettingsBlock(block: block, metricsService: metricsService);
      default:
        return Center(
          child: Text(
            'Unknown block: ${block.subtype}',
            style: const TextStyle(color: Colors.white),
          ),
        );
    }
  }

  static Color? _parseColor(String? hex) {
    if (hex == null) return null;
    hex = hex.replaceFirst('#', '');
    if (hex.length == 6) hex = 'FF$hex';
    final value = int.tryParse(hex, radix: 16);
    return value != null ? Color(value) : null;
  }
}

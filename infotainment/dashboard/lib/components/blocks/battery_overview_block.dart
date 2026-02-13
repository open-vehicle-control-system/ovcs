import 'package:flutter/material.dart';
import 'package:gauge_indicator/gauge_indicator.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:dashboard_flutter/models/block_config.dart';
import 'package:dashboard_flutter/services/metrics_service.dart';

/// Renders the HV battery overview: SOC gauge + voltage/current/temp/charging info.
class BatteryOverviewBlock extends StatelessWidget {
  final BlockConfig block;
  final MetricsService metricsService;

  const BatteryOverviewBlock({
    super.key,
    required this.block,
    required this.metricsService,
  });

  dynamic _metric(String key) {
    for (final m in block.metrics) {
      if (m.key == key) {
        return metricsService.getValue(m.module, m.key);
      }
    }
    return null;
  }

  double _doubleMetric(String key) {
    final v = _metric(key);
    if (v == null) return 0.0;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  @override
  Widget build(BuildContext context) {
    final packVoltage = _doubleMetric('pack_voltage');
    final packSoc = _doubleMetric('pack_state_of_charge');
    final packTemp = _doubleMetric('pack_average_temperature');
    final packCurrent = _doubleMetric('pack_current');
    final packIsCharging = _metric('pack_is_charging') == true;
    final j1772PlugState = (_metric('j1772_plug_state') as String?) ?? 'disconnected';

    return Row(
      children: [
        Expanded(
          flex: 1,
          child: Padding(
            padding: const EdgeInsets.only(left: 10.0, top: 10.0),
            child: AnimatedRadialGauge(
              duration: const Duration(milliseconds: 800),
              curve: Curves.easeOutCubic,
              value: packSoc,
              axis: GaugeAxis(
                min: 0,
                max: 100,
                degrees: 270,
                style: const GaugeAxisStyle(
                  thickness: 30,
                  background: Color(0xD9334155),
                  segmentSpacing: 0,
                ),
                progressBar: const GaugeProgressBar.basic(
                  color: Color(0xFF52cd85),
                ),
              ),
              builder: (context, child, value) => Center(
                child: Text(
                  '${value.toInt()}%',
                  style: const TextStyle(
                    fontSize: 18,
                    fontFamily: 'Lato',
                    color: Colors.white,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          flex: 1,
          child: Padding(
            padding: const EdgeInsets.only(left: 50.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _infoRow(Symbols.electric_meter, '${packVoltage}V ${packCurrent}A'),
                const SizedBox(height: 25),
                _infoRow(Symbols.thermostat, '${packTemp}\u00B0C'),
                const SizedBox(height: 25),
                _infoRow(Symbols.bolt, packIsCharging ? 'Charging' : 'Discharging'),
                const SizedBox(height: 25),
                _infoRow(
                  Symbols.electrical_services,
                  j1772PlugState.isNotEmpty
                      ? j1772PlugState[0].toUpperCase() + j1772PlugState.substring(1)
                      : 'Unknown',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _infoRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, color: Colors.grey, size: 20),
        const SizedBox(width: 14),
        Text(
          text,
          style: const TextStyle(
            fontSize: 16,
            color: Colors.grey,
            decoration: TextDecoration.none,
            fontFamily: 'Lato',
          ),
        ),
      ],
    );
  }
}

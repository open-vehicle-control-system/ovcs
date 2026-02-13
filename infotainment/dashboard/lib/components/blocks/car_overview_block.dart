import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:dashboard_flutter/models/block_config.dart';
import 'package:dashboard_flutter/services/metrics_service.dart';

/// Renders the car door overview with left/right car images and indicator icons.
/// Reads door states, beam, handbrake, and ready_to_drive from metrics.
class CarOverviewBlock extends StatelessWidget {
  final BlockConfig block;
  final MetricsService metricsService;

  const CarOverviewBlock({
    super.key,
    required this.block,
    required this.metricsService,
  });

  dynamic _metric(String key) {
    // Find the metric ref matching this key
    for (final m in block.metrics) {
      if (m.key == key) {
        return metricsService.getValue(m.module, m.key);
      }
    }
    return null;
  }

  bool _boolMetric(String key) => _metric(key) == true;

  @override
  Widget build(BuildContext context) {
    final frontLeftOpen = _boolMetric('front_left_door_open');
    final frontRightOpen = _boolMetric('front_right_door_open');
    final rearLeftOpen = _boolMetric('rear_left_door_open');
    final rearRightOpen = _boolMetric('rear_right_door_open');
    final beamActive = _boolMetric('beam_active');
    final handbrakeEngaged = _boolMetric('handbrake_engaged');
    final readyToDrive = _boolMetric('ready_to_drive');
    final trunkOpen = _boolMetric('trunk_door_open');

    final leftImage = _leftCarImage(frontLeftOpen, rearLeftOpen);
    final rightImage = _rightCarImage(frontRightOpen, rearRightOpen);

    return Column(
      children: [
        Expanded(
          flex: 8,
          child: Row(
            children: [
              Expanded(
                child: Image(
                  alignment: const Alignment(1.0, 0.0),
                  image: AssetImage(leftImage),
                ),
              ),
              Expanded(
                child: Image(
                  alignment: const Alignment(-1.0, 0.0),
                  image: AssetImage(rightImage),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          flex: 2,
          child: Row(
            children: [
              Expanded(child: _svgIcon('assets/images/engine.svg', readyToDrive)),
              Expanded(child: _svgIcon('assets/images/trunk.svg', trunkOpen)),
              Expanded(child: _svgIcon('assets/images/beams.svg', beamActive)),
              Expanded(child: _svgIcon('assets/images/handbrake.svg', handbrakeEngaged)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _svgIcon(String asset, bool active) {
    return Container(
      padding: const EdgeInsets.all(10.0),
      child: SvgPicture.asset(
        asset,
        colorFilter: ColorFilter.mode(
          active ? Colors.white : Colors.white24,
          BlendMode.srcIn,
        ),
      ),
    );
  }

  String _leftCarImage(bool frontOpen, bool rearOpen) {
    if (frontOpen && rearOpen) return 'assets/images/all_open_left.png';
    if (frontOpen) return 'assets/images/front_left_open.png';
    if (rearOpen) return 'assets/images/rear_left_open.png';
    return 'assets/images/all_closed_left.png';
  }

  String _rightCarImage(bool frontOpen, bool rearOpen) {
    if (frontOpen && rearOpen) return 'assets/images/all_open_right.png';
    if (frontOpen) return 'assets/images/front_right_open.png';
    if (rearOpen) return 'assets/images/rear_right_open.png';
    return 'assets/images/all_closed_right.png';
  }
}

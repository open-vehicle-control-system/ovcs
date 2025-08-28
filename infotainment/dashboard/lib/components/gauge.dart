import 'package:dashboard_flutter/services/socket_service.dart';
import 'package:flutter/material.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:syncfusion_flutter_gauges/gauges.dart';

class OVCSGauge extends StatefulWidget {
  final String unit;
  final double min;
  final double max;
  final String source;

  const OVCSGauge({
    super.key,
    required this.unit,
    required this.min,
    required this.max,
    required this.source,
  });

  @override
  State<OVCSGauge> createState() => _OVCSGaugeState();
}

class _OVCSGaugeState extends State<OVCSGauge> {
  double currentValue = 0.0;
  PhoenixChannel? _channel;

  @override
  void initState() {
    super.initState();
    PhoenixSocket socket = SocketService.socket;
    _channel = socket.addChannel(topic: 'status', parameters: {"interval": 50});

    socket.openStream.listen((event) {
      _channel?.join();
    });

    _channel?.messages.listen((event) {
      if (event.topic == "status" && event.payload!.containsKey("attributes")) {
        final valueStr = event.payload!["attributes"][widget.source];
        if (valueStr != null) {
          setState(() {
            currentValue = double.tryParse(valueStr.toString()) ?? 0.0;
          });
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        double size = constraints.biggest.shortestSide;

        double pointerWidth = size * 0.08;
        double axisThickness = size * 0.08;
        double majorTickLength = size * 0.025;
        double minorTickLength = size * 0.007;
        double valueFontSize = size * 0.16;
        double unitFontSize = size * 0.08;

        return Container(
          height: size,
          width: size,

          decoration: BoxDecoration(
            color: const Color(0xD9111827),
            borderRadius: BorderRadius.circular(20),
          ),
          child: SfRadialGauge(
            animationDuration: 1000,
            enableLoadingAnimation: true,
            axes: [
              RadialAxis(
                minimum: widget.min,
                maximum: widget.max,
                interval: ((widget.max - widget.min) / 10).roundToDouble(),
                endAngle: 45,
                startAngle: -225,
                tickOffset: size * 0.015,
                showLabels: false,
                axisLineStyle: AxisLineStyle(
                  thickness: axisThickness,
                  color: const Color(0xD9334155),
                ),
                minorTickStyle: MinorTickStyle(
                  color: const Color(0XFF64748b),
                  length: minorTickLength,
                ),
                majorTickStyle: MajorTickStyle(
                  color: const Color(0XFF64748b),
                  length: majorTickLength,
                ),
                pointers: [
                  RangePointer(
                    width: pointerWidth,
                    value: currentValue,
                    gradient: const SweepGradient(
                      colors: [
                        Color(0xFF8b5cf6),
                        Color(0xFF7c3aed),
                        Color(0xFF6d28d9),
                        Color(0xff5b21b6),
                        Color(0xFF4c1d95),
                      ],
                      stops: [0, 0.25, 0.5, 0.75, 1],
                    ),
                  ),
                ],
                annotations: [
                  GaugeAnnotation(
                    verticalAlignment: GaugeAlignment.center,
                    widget: Text(
                      currentValue.toInt().toString(),
                      style: TextStyle(
                        fontSize: valueFontSize,
                        fontFamily: 'Lato',
                        color: Colors.white,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    angle: 90,
                    positionFactor: 0,
                  ),
                  GaugeAnnotation(
                    verticalAlignment: GaugeAlignment.near,
                    widget: Text(
                      widget.unit,
                      style: TextStyle(
                        fontSize: unitFontSize,
                        fontFamily: 'Lato',
                        color: Colors.grey,
                        decoration: TextDecoration.none,
                        height: 2.2,
                      ),
                    ),
                    angle: 90,
                    positionFactor: 0,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

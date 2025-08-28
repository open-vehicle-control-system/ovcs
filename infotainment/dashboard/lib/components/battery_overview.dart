import 'package:dashboard_flutter/services/socket_service.dart';
import 'package:flutter/material.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:syncfusion_flutter_gauges/gauges.dart';
import 'package:material_symbols_icons/symbols.dart';

class BatteryOverview extends StatefulWidget {
  const BatteryOverview({super.key});

  @override
  State<BatteryOverview> createState() => _BatteryOverviewState();
}

class _BatteryOverviewState extends State<BatteryOverview> {
  double packVoltage = 0.0;
  double packStateOfCharge = 0.0;
  double packAverageTemperature = 0.0;
  double packCurrent = 0.0;
  bool packIsCharging = false;
  String j1772PlugState = "disconnected";

  PhoenixChannel? _channel;

  @override
  void initState() {
    super.initState();
    PhoenixSocket socket = SocketService.socket;
    _channel = socket.addChannel(topic: 'status', parameters: {"interval": 50});

    _channel?.messages.listen((event) {
      if (event.topic == "status" && event.payload!.containsKey("attributes")) {
        setState(() {
          packVoltage =
              double.parse(event.payload!["attributes"]["packVoltage"]);
          packStateOfCharge =
              double.parse(event.payload!["attributes"]["packStateOfCharge"]);
          packAverageTemperature = double.parse(
              event.payload!["attributes"]["packAverageTemperature"]);
          packCurrent =
              double.parse(event.payload!["attributes"]["packCurrent"]);
          packIsCharging = event.payload!["attributes"]["packIsCharging"];
          j1772PlugState = event.payload!["attributes"]["j1772PlugState"];
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        double size = constraints.biggest.shortestSide;

        double width = constraints.maxWidth;
        double height = width / 2.15;

        double gaugeSize = height * 0.9;
        double gaugeThickness = gaugeSize * 0.15;
        double valueFontSize = gaugeSize * 0.09;

        return Container(
          height: height,
          width: width,
          decoration: BoxDecoration(
            color: const Color(0xD9111827),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              SizedBox(
                width: gaugeSize,
                height: gaugeSize,
                child: SfRadialGauge(
                  animationDuration: 4000,
                  enableLoadingAnimation: true,
                  axes: [
                    RadialAxis(
                      minimum: 0,
                      maximum: 100,
                      startAngle: -225,
                      endAngle: 45,
                      showTicks: false,
                      showLabels: false,
                      axisLineStyle: AxisLineStyle(
                        thickness: gaugeThickness,
                        color: const Color(0xD9334155),
                      ),
                      pointers: [
                        RangePointer(
                          value: packStateOfCharge,
                          width: gaugeThickness,
                          color: const Color(0xFF52cd85),
                        ),
                      ],
                      annotations: [
                        GaugeAnnotation(
                          verticalAlignment: GaugeAlignment.center,
                          widget: Text(
                            "${packStateOfCharge.toInt()}%",
                            style: TextStyle(
                              fontSize: valueFontSize,
                              color: Colors.white,
                              fontFamily: 'Lato',
                              decoration: TextDecoration.none,
                            ),
                          ),
                          angle: 90,
                          positionFactor: 0,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _infoRow(Icons.electric_meter, "${packVoltage}V ${packCurrent}A", height),
                    SizedBox(height: height * 0.06),
                    _infoRow(Icons.thermostat, "${packAverageTemperature}°C", height),
                    SizedBox(height: height * 0.06),
                    _infoRow(Icons.bolt, packIsCharging ? "Charging" : "Discharging", height),
                    SizedBox(height: height * 0.06),
                    _infoRow(Icons.electrical_services,
                        j1772PlugState[0].toUpperCase() + j1772PlugState.substring(1), height),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _infoRow(IconData icon, String text, double containerHeight) {
    double fontSize = containerHeight * 0.15 * 0.5;
    double iconSize = fontSize * 1.2;

    return Row(
      children: [
        Icon(icon, color: Colors.grey, size: iconSize),
        SizedBox(width: iconSize * 0.7),
        Text(
          text,
          style: TextStyle(
            fontSize: fontSize,
            color: Colors.grey,
            fontFamily: 'Lato',
            decoration: TextDecoration.none,
          ),
        ),
      ],
    );
  }
}

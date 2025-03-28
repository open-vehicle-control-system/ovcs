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
  _BatteryOverviewState() {
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
    return Container(
        width: MediaQuery.of(context).size.width * 0.43,
        height: MediaQuery.of(context).size.width * 0.20,
        margin: const EdgeInsets.all(10.0),
        padding: const EdgeInsets.all(30.0),
        decoration: BoxDecoration(
            color: const Color(0xD9111827),
            borderRadius: BorderRadius.circular(30)),
        child: Row(children: [
          Expanded(
              flex: 1,
              child: Padding(
                  padding: const EdgeInsets.only(left: 10.0, top: 10.0),
                  child: SfRadialGauge(
                      animationDuration: 4000,
                      enableLoadingAnimation: true,
                      axes: <RadialAxis>[
                        RadialAxis(
                            interval: 25,
                            endAngle: 45,
                            startAngle: -225,
                            tickOffset: 5.0,
                            showLabels: false,
                            showTicks:
                                false, // Hides both minor and major ticks
                            axisLineStyle: const AxisLineStyle(
                              thickness: 30,
                              color: Color(0xD9334155),
                            ),
                            pointers: <GaugePointer>[
                              RangePointer(
                                width: 30,
                                value: packStateOfCharge,
                                color: Color(
                                    0xFF52cd85), // Single color for the bar
                              )
                            ],
                            annotations: <GaugeAnnotation>[
                              GaugeAnnotation(
                                  verticalAlignment: GaugeAlignment.center,
                                  widget: Text("${packStateOfCharge.toInt()}%",
                                      style: const TextStyle(
                                        fontSize: 18,
                                        fontFamily: 'Lato',
                                        color: Colors.white,
                                        decoration: TextDecoration.none,
                                      )),
                                  angle: 90,
                                  positionFactor: 0)
                            ])
                      ]))),
          Expanded(
              flex: 1,
              child: Padding(
                padding: const EdgeInsets.only(left: 50.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        Icon(Symbols.electric_meter,
                            color: Colors.grey, size: 20),
                        SizedBox(width: 14),
                        Text(
                          "${packVoltage}V ${packCurrent}A",
                          style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey,
                              decoration: TextDecoration.none,
                              fontFamily: 'Lato'),
                        ),
                      ],
                    ),
                    SizedBox(height: 25),
                    Row(
                      children: [
                        Icon(Symbols.thermostat, color: Colors.grey, size: 20),
                        SizedBox(width: 14),
                        Text(
                          "${packAverageTemperature}°C",
                          style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey,
                              decoration: TextDecoration.none,
                              fontFamily: 'Lato'),
                        ),
                      ],
                    ),
                    SizedBox(height: 25),
                    Row(
                      children: [
                        Icon(Symbols.bolt, color: Colors.grey, size: 20),
                        SizedBox(width: 14),
                        Text(
                          packIsCharging ? "Charging" : "Discharging",
                          style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey,
                              decoration: TextDecoration.none,
                              fontFamily: 'Lato'),
                        ),
                      ],
                    ),
                    SizedBox(height: 25),
                    Row(
                      children: [
                        Icon(Symbols.electrical_services,
                            color: Colors.grey, size: 20),
                        SizedBox(width: 14),
                        Text(
                          j1772PlugState[0].toUpperCase() +
                              j1772PlugState.substring(1),
                          style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey,
                              decoration: TextDecoration.none,
                              fontFamily: 'Lato'),
                        ),
                      ],
                    ),
                  ],
                ),
              ))
        ]));
  }
}

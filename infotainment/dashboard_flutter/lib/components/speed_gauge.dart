
import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:syncfusion_flutter_gauges/gauges.dart';
import 'package:phoenix_socket/phoenix_socket.dart';

class SpeedGauge extends StatefulWidget {
  const SpeedGauge({super.key});

  @override
  State<SpeedGauge> createState() => _SpeedGaugeState();
}

class _SpeedGaugeState extends State<SpeedGauge> {

  int currentSpeed = 0;

  _SpeedGaugeState() {
    final channel = WebSocketChannel.connect(
      Uri.parse("ws://127.0.0.1:4001/dashboard"),
    );

    channel.stream.listen( (message) {
      print("received message: $message");
    });
  }

  @override
  Widget build(BuildContext context){
    return Container(
      height: MediaQuery.of(context).size.width * 0.32,
      width: MediaQuery.of(context).size.width * 0.37,
      margin: const EdgeInsets.all(10.0),
      padding: const EdgeInsets.only(left: 20.0, right: 20.0, top: 30.0),
      decoration: BoxDecoration(
        color: const Color(0xD9111827),
        borderRadius: BorderRadius.circular(30)
      ),
      child: SfRadialGauge(
        animationDuration: 4000,
        enableLoadingAnimation: true,
        axes: <RadialAxis>[
            RadialAxis(
              interval: 10,
              endAngle: 45,
              startAngle: -225,
              tickOffset: 5.0,
              showLabels: false,
              axisLineStyle: const AxisLineStyle(
                thickness: 30,
                color: Color(0xD9334155),
              ),
              minorTickStyle: const MinorTickStyle(
                color: Color(0XFF64748b),
                length: 2.0
              ),
              majorTickStyle: const MajorTickStyle(
                color: Color(0XFF64748b),
                length: 8.0
              ),
              pointers: <GaugePointer>[
                RangePointer(
                    width: 30,
                    value: currentSpeed.toDouble(),
                    gradient: const SweepGradient(colors: <Color>[
                      Color(0xFF8b5cf6),
                      Color(0xFF7c3aed),
                      Color(0xFF6d28d9),
                      Color(0xff5b21b6),
                      Color(0xFF4c1d95),
                    ], stops: <double>[
                      0,
                      0.25,
                      0.5,
                      0.75,
                      1
                    ]
                  ),
                )
              ],
              annotations: <GaugeAnnotation>[
                GaugeAnnotation(
                    verticalAlignment: GaugeAlignment.center,
                    widget: Text(currentSpeed.toString(),
                          style: const TextStyle(
                              fontSize: 100,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              decoration: TextDecoration.none,
                            )
                          ),
                    angle: 90,
                    positionFactor: 0
                  ),
                  const GaugeAnnotation(
                    verticalAlignment: GaugeAlignment.near,
                    widget: Text("km/h",
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey,
                        decoration: TextDecoration.none,
                        height: 6.0
                      )
                    ),
                    angle: 90,
                    positionFactor: 0
                  )
              ]
            )
          ]
        )
    );
  }
}
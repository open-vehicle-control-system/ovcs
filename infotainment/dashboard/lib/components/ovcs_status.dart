import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:dashboard_flutter/services/socket_service.dart';
import 'package:phoenix_socket/phoenix_socket.dart';


class OvcsStatus extends StatefulWidget {
  const OvcsStatus({super.key});

  @override
  State<OvcsStatus> createState() => _OvcsStatusState();
}

class _OvcsStatusState extends State<OvcsStatus> {

  bool vmsMissing = true;
  bool frontControllerMissing = true;
  bool rearControllerMissing = true;
  bool controlsControllerMissing = true;
  bool inverterMissing = true;
  bool bmsMissing = true;
  bool mainNegativeOff = true;
  bool mainPositiveOff = true;
  bool preChargeOff = true;

  PhoenixChannel? _channel;
  _OvcsStatusState() {
    PhoenixSocket socket = SocketService.socket;
    _channel = socket.addChannel(topic: 'status', parameters: {"interval": 100});

    socket.openStream.listen((event) {
      setState(() {
        _channel?.join();
      });
    });

    _channel?.messages.listen( (event){
      String jsonsDataString = event.payload.toString();
      log(jsonsDataString);
      if(event.topic == "status" && event.payload!.containsKey("attributes")){
        setState(() {
          vmsMissing = event.payload!["attributes"]["vms_missing"];
          frontControllerMissing = event.payload!["attributes"]["front_controller_missing"];
          rearControllerMissing = event.payload!["attributes"]["rear_controller_missing"];
          controlsControllerMissing = event.payload!["attributes"]["controls_controller_missing"];
          inverterMissing = event.payload!["attributes"]["inverter_missing"];
          bmsMissing = event.payload!["attributes"]["bms_missing"];
          mainNegativeOff = event.payload!["attributes"]["main_negative_off"];
          mainPositiveOff = event.payload!["attributes"]["main_positive_off"];
          preChargeOff = event.payload!["attributes"]["precharge_off"];
        });
      }
    });
  }

  @override
  Widget build(BuildContext context){
    return Container(
      width: MediaQuery.of(context).size.width * 0.43,
      height: MediaQuery.of(context).size.width * 0.20,
      margin: const EdgeInsets.only(left: 7.0),
      padding: const EdgeInsets.all(10.0),
      decoration: BoxDecoration(
        color: const Color(0xD9111827),
        borderRadius: BorderRadius.circular(30)
      ),
      child: Row(
        children: [
          Column(
            children: [
              ComponentStatusBox(name: "Vehicle Management System", missing: vmsMissing),
              ComponentStatusBox(name: "Front Controler", missing: frontControllerMissing),
              ComponentStatusBox(name: "Rear Controler", missing: rearControllerMissing),
            ],
          ),
          Column(
            children: [
              ComponentStatusBox(name: "Controls Controler", missing: controlsControllerMissing),
              ComponentStatusBox(name: "BMS", missing: bmsMissing),
              ComponentStatusBox(name: "Inverter enabled", missing: inverterMissing),
            ]
          ),
          Column(
            children: [
              ComponentStatusBox(name: "Main Negative", missing: mainNegativeOff),
              ComponentStatusBox(name: "Main Positive", missing: mainPositiveOff),
              ComponentStatusBox(name: "Precharge", missing: preChargeOff),
            ]
          ),
        ],
      )
    );
  }
}

class ComponentStatusBox extends StatefulWidget {
  final String name;
  final bool missing;
  const ComponentStatusBox({super.key,required this.name, required this.missing});

  @override
  State<ComponentStatusBox> createState() => _ComponentStatusBox();
}

class _ComponentStatusBox extends State<ComponentStatusBox> {
  static const TextStyle textOn = TextStyle(
    fontSize: 16,
    color: Color.fromRGBO(238, 155, 117, 1),
    decoration: TextDecoration.none,
    height: 1,
  );

  static const TextStyle textOff = TextStyle(
    fontSize: 16,
    color: Color.fromRGBO(238, 155, 117, 0.3),
    decoration: TextDecoration.none,
    height: 1,
  );

  static BoxDecoration boxOn = BoxDecoration(
    border: Border.all(color: const Color.fromRGBO(238, 155, 117, 1), width: 2),
    borderRadius: BorderRadius.circular(10)
  );

  static BoxDecoration boxOff = BoxDecoration(
    border: Border.all(color: const Color.fromRGBO(238, 155, 117, 0.3), width: 2),
    borderRadius: BorderRadius.circular(10)
  );

  @override
  Widget build(BuildContext context){
    return Container(
      margin: const EdgeInsets.all(7),
      width: 162,
      height: 64,
      decoration: widget.missing? boxOff : boxOn,
      child: Center(child: Text(widget.name, style: widget.missing? textOff : textOn, textAlign: TextAlign.center)),
    );
  }
}
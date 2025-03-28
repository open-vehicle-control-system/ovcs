import 'package:flutter/material.dart';
import 'package:dashboard_flutter/services/socket_service.dart';
import 'package:phoenix_socket/phoenix_socket.dart';


class OvcsStatus extends StatefulWidget {
  const OvcsStatus({super.key});

  @override
  State<OvcsStatus> createState() => _OvcsStatusState();
}

class _OvcsStatusState extends State<OvcsStatus> {

  String vmsStatus = "MISSING";
  String frontControlerStatus = "MISSING";
  String rearControllerStatus = "MISSING";
  String controlsControllerStatus = "MISSING";
  String bmsStatus = "MISSING";
  bool inverterEnabled = false;
  bool mainNegativeContactorEnabled = false;
  bool mainPositiveContactorEnabled = false;
  bool prechargeContactorEnabled = false;

  PhoenixChannel? _channel;
  _OvcsStatusState() {
    PhoenixSocket socket = SocketService.socket;
    _channel = socket.addChannel(topic: 'status', parameters: {"interval": 50});

    _channel?.messages.listen( (event){
      if(event.topic == "status" && event.payload!.containsKey("attributes")){
        setState(() {
          vmsStatus = event.payload!["attributes"]["vmsStatus"];
          frontControlerStatus = event.payload!["attributes"]["frontControlerStatus"];
          rearControllerStatus = event.payload!["attributes"]["rearControllerStatus"];
          controlsControllerStatus = event.payload!["attributes"]["controlsControllerStatus"];
          inverterEnabled = event.payload!["attributes"]["inverterEnabled"];
          bmsStatus = "MISSING"; //TO CHANGE WHEN BMS IS FULLY OPERATIONAL
          mainNegativeContactorEnabled = event.payload!["attributes"]["mainNegativeContactorEnabled"];
          mainPositiveContactorEnabled = event.payload!["attributes"]["mainPositiveContactorEnabled"];
          prechargeContactorEnabled = event.payload!["attributes"]["prechargeContactorEnabled"];
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
              ComponentStatusBox(name: "Vehicle Management System", status: vmsStatus),
              ComponentStatusBox(name: "Front Controler", status: frontControlerStatus),
              ComponentStatusBox(name: "Rear Controler", status: rearControllerStatus),
            ],
          ),
          Column(
            children: [
              ComponentStatusBox(name: "Controls Controler", status: controlsControllerStatus),
              ComponentStatusBox(name: "BMS", status: bmsStatus),
              ComponentStatusBox(name: "Inverter enabled", status: inverterEnabled.toString()),
            ]
          ),
          Column(
            children: [
              ComponentStatusBox(name: "Main Negative", status: mainNegativeContactorEnabled.toString()),
              ComponentStatusBox(name: "Main Positive", status: mainPositiveContactorEnabled.toString()),
              ComponentStatusBox(name: "Precharge", status: prechargeContactorEnabled.toString()),
            ]
          ),
        ],
      )
    );
  }
}

class ComponentStatusBox extends StatefulWidget {
  final String name;
  final String status;
  const ComponentStatusBox({super.key,required this.name, required this.status});

  @override
  State<ComponentStatusBox> createState() => _ComponentStatusBox();
}

class _ComponentStatusBox extends State<ComponentStatusBox> {
  BoxDecoration getBoxDecorationForStatus(String status) {
    switch(status){
      case "MISSING" || "false":
        return boxOff;
      case "OK" || "true":
        return boxOn;
      default:
        return boxError;
    };
  }

    TextStyle getTextStyleForStatus(String status) {
    switch(status){
      case "MISSING" || "false":
        return textOff;
      case "OK" || "true":
        return textOn;
      default:
        return textError;
    };
  }

  static const TextStyle textOn = TextStyle(
    fontSize: 16,
    color: Color.fromRGBO(238, 155, 117, 1),
    decoration: TextDecoration.none,
    height: 1,
    fontFamily: 'Lato',
  );

  static const TextStyle textOff = TextStyle(
    fontSize: 16,
    color: Color.fromRGBO(238, 155, 117, 0.3),
    decoration: TextDecoration.none,
    height: 1,
    fontFamily: 'Lato',
  );

  static const TextStyle textError = TextStyle(
    fontSize: 16,
    color: Color.fromRGBO(188, 48, 53, 1),
    decoration: TextDecoration.none,
    height: 1,
    fontFamily: 'Lato',
  );

  static BoxDecoration boxOn = BoxDecoration(
    border: Border.all(color: const Color.fromRGBO(238, 155, 117, 1), width: 2),
    borderRadius: BorderRadius.circular(10)
  );

  static BoxDecoration boxOff = BoxDecoration(
    border: Border.all(color: const Color.fromRGBO(238, 155, 117, 0.3), width: 2),
    borderRadius: BorderRadius.circular(10)
  );

  static BoxDecoration boxError = BoxDecoration(
    border: Border.all(color: const Color.fromRGBO(188, 48, 53, 1), width: 2),
    borderRadius: BorderRadius.circular(10)
  );

  @override
  Widget build(BuildContext context){
    return Container(
      margin: const EdgeInsets.all(7),
      width: 162,
      height: 64,
      decoration: getBoxDecorationForStatus(widget.status),
      child: Center(child: Text(widget.name, style: getTextStyleForStatus(widget.status), textAlign: TextAlign.center)),
    );
  }
}
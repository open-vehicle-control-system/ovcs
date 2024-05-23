import 'package:dashboard_flutter/components/car_view.dart';
import 'package:dashboard_flutter/components/icons/icons.dart';
import 'package:dashboard_flutter/services/socket_service.dart';
import 'package:flutter/material.dart';
import 'package:phoenix_socket/phoenix_socket.dart';

class CarOverview extends StatefulWidget {
  const CarOverview({super.key});

  @override
  State<CarOverview> createState() => _CarOverviewState();
}

class _CarOverviewState extends State<CarOverview> {

  PhoenixChannel? _channel;

  Widget handBrakeIcon = OvcsIcons.handBrakeOffSvg;
  Widget beamsIcon = OvcsIcons.beamsOffSvg;
  Widget trunkIcon = OvcsIcons.trunkClosedSvg;
  Widget engineIcon = OvcsIcons.engineOffSvg;

  AssetImage carLeftView = CarView.allClosedLeft;
  AssetImage carRightView = CarView.allClosedRight;

  _CarOverviewState() {
    PhoenixSocket socket = SocketService.socket;
    _channel = socket.addChannel(topic: 'car-overview', parameters: {"interval": 500});

    socket.openStream.listen((event) {
      setState(() {
        _channel?.join();
      });
    });

    _channel?.messages.listen( (event){
      if(event.topic == "car-overview" && event.payload!.containsKey("vms_status")){
        setState(() {
          handBrakeIcon = OvcsIcons.toggleHandrakeIcon(event);
          beamsIcon = OvcsIcons.toggleBeamsIcon(event);
          trunkIcon = OvcsIcons.toggleTrunkIcon(event);
          engineIcon = OvcsIcons.toggleEngineIcon(event);
          carLeftView = CarView.updateLeftView(event);
          carRightView = CarView.updateRightView(event);
        },);
      }
    });
  }

  @override
  Widget build(BuildContext context){
    return Container(
      width: MediaQuery.of(context).size.width * 0.37,
      height: MediaQuery.of(context).size.width * 0.38,
      margin: const EdgeInsets.all(10.0),
      padding: const EdgeInsets.all(20.0),
      decoration: BoxDecoration(
        color: const Color(0xD9111827),
        borderRadius: BorderRadius.circular(30)
      ),
      child: Column(children: [
         Expanded(
          flex: 8,
          child: Row(
            children: [
              Expanded(
                child:
                  Image(
                    alignment: const Alignment(1.0, 0.0),
                    image: carLeftView
                  )
                ),
              Expanded(
                child:
                  Image(
                    alignment: const Alignment(-1.0, 0.0),
                    image: carRightView
                  )
                )
            ]
          )
        ),
        Expanded(
          flex: 2,
          child: Row(children: [
            Expanded( child:
              Container(
              padding: const EdgeInsets.all(10.0),
              child: engineIcon
            )),
            Expanded( child:
              Container(
              padding: const EdgeInsets.all(10.0),
              child: trunkIcon
            )),
            Expanded( child:
              Container(
              padding: const EdgeInsets.all(10.0),
              child: beamsIcon
            )),
            Expanded( child:
              Container(
              padding: const EdgeInsets.all(10.0),
              child: handBrakeIcon
            ))
        ]))
      ])
    );
  }
}
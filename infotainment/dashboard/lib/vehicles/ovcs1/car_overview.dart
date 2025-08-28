import 'package:dashboard_flutter/vehicles/ovcs1/car_view.dart';
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
    _channel = socket.addChannel(topic: 'status', parameters: {"interval": 50});

    _channel?.messages.listen((event) {
      if (event.topic == "status" && event.payload!.containsKey("attributes")) {
        setState(() {
          handBrakeIcon = OvcsIcons.toggleHandrakeIcon(event);
          beamsIcon = OvcsIcons.toggleBeamsIcon(event);
          trunkIcon = OvcsIcons.toggleTrunkIcon(event);
          engineIcon = OvcsIcons.toggleEngineIcon(event);
          carLeftView = CarView.updateLeftView(event);
          carRightView = CarView.updateRightView(event);
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Base size for scaling everything
    double size = MediaQuery.of(context).size.width;

    return Container(
      width: size * 0.37,
      height: size * 0.38,
      decoration: BoxDecoration(
        color: const Color(0xD9111827),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          // Car images
          Expanded(
            flex: 8,
            child: Row(
              children: [
                Expanded(
                  child: Image(
                    alignment: const Alignment(1.0, 0.0),
                    image: carLeftView,
                  ),
                ),
                Expanded(
                  child: Image(
                    alignment: const Alignment(-1.0, 0.0),
                    image: carRightView,
                  ),
                ),
              ],
            ),
          ),
          // Icons row
          Expanded(
            flex: 2,
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.all(size * 0.01), // dynamic padding
                    child: engineIcon,
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.all(size * 0.01),
                    child: trunkIcon,
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.all(size * 0.01),
                    child: beamsIcon,
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.all(size * 0.01),
                    child: handBrakeIcon,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

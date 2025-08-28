import 'dart:convert';

import 'package:dashboard_flutter/services/socket_service.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:phoenix_socket/phoenix_socket.dart';

class GearSelector extends StatefulWidget {
  const GearSelector({super.key});

  @override
  State<GearSelector> createState() => _GearSelectorState();
}

class _GearSelectorState extends State<GearSelector> {
  String gear = "parking";
  PhoenixChannel? _channel;

  _GearSelectorState() {
    PhoenixSocket socket = SocketService.socket;
    _channel = socket.addChannel(topic: 'status', parameters: {"interval": 50});

    _channel?.messages.listen((event) {
      if (event.topic == "status" && event.payload!.containsKey("attributes")) {
        setState(() {
          gear = event.payload?["attributes"]["selectedGear"];
        });
      }
    });
  }

  void requestGear(String gear) async {
    const apiUrl = "http://localhost:4001/api/gear-selector";
    await http.post(
      Uri.parse(apiUrl),
      headers: <String, String>{'Content-Type': 'application/json; charset=UTF-8'},
      body: jsonEncode(<String, String>{'gear': gear}),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 0.8, // height slightly larger than width
      child: LayoutBuilder(
        builder: (context, constraints) {
          double size = constraints.biggest.shortestSide;

          double buttonHeight = constraints.maxHeight / 4.5;
          double buttonWidth = constraints.maxWidth * 0.9;
          double fontSize = buttonHeight * 0.5;

          return Container(
            padding: EdgeInsets.all(constraints.maxWidth * 0.05),
            decoration: BoxDecoration(
              color: const Color(0xD9111827),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _gearButton("P", "parking", buttonWidth, buttonHeight, fontSize),
                _gearButton("R", "reverse", buttonWidth, buttonHeight, fontSize),
                _gearButton("N", "neutral", buttonWidth, buttonHeight, fontSize),
                _gearButton("D", "drive", buttonWidth, buttonHeight, fontSize),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _gearButton(String label, String value, double width, double height, double fontSize) {
    return TextButton(
      onPressed: () => requestGear(value),
      style: TextButton.styleFrom(
        fixedSize: Size(width, height),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(width * 0.2)),
        backgroundColor: gear == value ? const Color(0x40FFFFFF) : Colors.transparent,
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: fontSize, color: Colors.white, decoration: TextDecoration.none),
      ),
    );
  }
}

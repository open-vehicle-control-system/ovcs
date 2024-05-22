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
    _channel = socket.addChannel(topic: 'gear', parameters: {"interval": 50});

    socket.openStream.listen((event) {
      setState(() {
        _channel?.join();
      });
    });

    _channel?.messages.listen( (event){
      if(event.topic == "gear" && event.payload!.containsKey("gear")){
        setState(() {
          gear = event.payload?["gear"];
        });
      }
    });
  }

  void requestGear(String gear) async {
    const apiUrl = "http://localhost:4001/api/gear-selector";
    await http.post(
      Uri.parse(apiUrl),
      headers: <String, String>{
        'Content-Type': 'application/json; charset=UTF-8',
      },
      body: jsonEncode(<String, String>{
        'gear': gear,
      }),
    );
  }

  @override
  Widget build(BuildContext context){
    return Container(
      width: MediaQuery.of(context).size.width * 0.1,
      height: MediaQuery.of(context).size.width * 0.32,
      margin: const EdgeInsets.all(10.0),
      padding: const EdgeInsets.all(20.0),
      decoration: BoxDecoration(
        color: const Color(0xD9111827),
        borderRadius: BorderRadius.circular(30)
      ),
      child: Column(
        children:[
          TextButton(
            onPressed: () { requestGear("parking"); },
            style: TextButton.styleFrom(
              fixedSize: const Size(90, 90),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              backgroundColor: gear == "parking" ? Color(0x40FFFFFF) : Color(0x00FFFFFF)
            ),
            child: const Text("P", style: TextStyle(fontSize: 36, color: Colors.white, decoration: TextDecoration.none))
          ),

          TextButton(
            onPressed: () { requestGear("reverse"); },
            style: TextButton.styleFrom(
              fixedSize: const Size(90, 90),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              backgroundColor: gear == "reverse" ? Color(0x40FFFFFF) : Color(0x00FFFFFF)
            ),
            child: const Text("R", style: TextStyle(fontSize: 36, color: Colors.white, decoration: TextDecoration.none))
          ),

          TextButton(
            onPressed: () { requestGear("neutral"); },
            style: TextButton.styleFrom(
              fixedSize: const Size(90, 90),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              backgroundColor: gear == "neutral" ? Color(0x40FFFFFF) : Color(0x00FFFFFF)
            ),
            child: const Text("N", style: TextStyle(fontSize: 36, color: Colors.white, decoration: TextDecoration.none))
          ),

          TextButton(
            onPressed: () { requestGear("drive"); },
            style: TextButton.styleFrom(
              fixedSize: const Size(90, 90),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              backgroundColor: gear == "drive" ? Color(0x40FFFFFF) : Color(0x00FFFFFF)
            ),
            child: const Text("D", style: TextStyle(fontSize: 36, color: Colors.white, decoration: TextDecoration.none))
          ),
        ]
      )
    );
  }
}
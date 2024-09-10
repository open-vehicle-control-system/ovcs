import 'package:dashboard_flutter/services/socket_service.dart';
import 'package:flutter/material.dart';
import 'package:phoenix_socket/phoenix_socket.dart';

String getTime() {
  String hours = DateTime.now().hour.toString().padLeft(2, '0');
  String minutes = DateTime.now().minute.toString().padLeft(2, '0');
  String seconds = DateTime.now().second.toString().padLeft(2, '0');
  String currentTime = '$hours:$minutes:$seconds';
  return currentTime;
}

String getDate() {
  String day = DateTime.now().day.toString().padLeft(2, '0');
  String month = DateTime.now().month.toString().padLeft(2, '0');
  String year = DateTime.now().year.toString();
  String currentDate = '$day/$month/$year';
  return currentDate;
}

class SideBar extends StatefulWidget {
  const SideBar({super.key});

  @override
  State<SideBar> createState() => _SideBarState();
}

class _SideBarState extends State<SideBar> {
  String timeVar = getTime();
  String dateVar = getDate();
  double temperature = 0.0;

  PhoenixChannel? _channel;
  _SideBarState() {
    PhoenixSocket socket = SocketService.socket;
    _channel = socket.addChannel(topic: 'temperature', parameters: {"interval": 1000});

    socket.openStream.listen((event) {
      setState(() {
        _channel?.join();
      });
    });

    _channel?.messages.listen( (event){
      if(event.topic == "temperature" && event.payload!.containsKey("temperature")){
        setState(() {
          temperature = event.payload!["temperature"];
        });
      }
    });
  }

  @override
  Widget build(BuildContext context){
    return Container(
      color: const Color(0xFF111827),
      child:
        Column(
          children: [
            Container(
              padding: const EdgeInsets.all(20.0) ,
              child: Column(
                children: [
                  Text(timeVar, style: const TextStyle(fontSize: 16, color: Colors.white, decoration: TextDecoration.none, fontFamily: 'Lato'),),
                  Text(dateVar, style: const TextStyle(fontSize: 16, color: Colors.white, decoration: TextDecoration.none, fontFamily: 'Lato')),
                  Padding(padding: const EdgeInsets.all(12), child: Row(children: [
                    const Icon(
                      Icons.memory_outlined,
                      color: Colors.white,
                      size: 16
                    ),
                    Text(temperature.toString(), style: const TextStyle(fontSize: 16, color: Colors.white, decoration: TextDecoration.none, fontFamily: 'Lato')),
                    const Text("°C", style: TextStyle(fontSize: 16, color: Colors.white, decoration: TextDecoration.none, fontFamily: 'Lato'))
                  ],),
                  )
                ]
              )
            ),
            Container()
          ]
        )
    );
  }
}
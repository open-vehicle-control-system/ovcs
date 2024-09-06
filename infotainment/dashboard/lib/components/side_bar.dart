import 'package:flutter/material.dart';


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

  @override
  void initState() {
    super.initState();
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
                  Text(dateVar, style: const TextStyle(fontSize: 16, color: Colors.white, decoration: TextDecoration.none, fontFamily: 'Lato'))
                ]
              )
            ),
            Container()
          ]
        )
    );
  }
}
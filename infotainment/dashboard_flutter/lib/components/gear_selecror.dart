import 'package:flutter/material.dart';

class GearSelector extends StatelessWidget {
  const GearSelector({super.key});

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
      child: const Column(
        children:[
          Text("P", style: TextStyle(fontSize: 36, color: Colors.white, decoration: TextDecoration.none)),
          Text("R", style: TextStyle(fontSize: 36, color: Colors.white, decoration: TextDecoration.none)),
          Text("N", style: TextStyle(fontSize: 36, color: Colors.white, decoration: TextDecoration.none)),
          Text("D", style: TextStyle(fontSize: 36, color: Colors.white, decoration: TextDecoration.none))
        ]
      )
    );
  }
}
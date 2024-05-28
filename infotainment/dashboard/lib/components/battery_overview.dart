import 'package:flutter/material.dart';

class BatteryOverview extends StatelessWidget{
  const BatteryOverview({super.key});

  @override
  Widget build(BuildContext context){
    return                     Container(
      width: MediaQuery.of(context).size.width * 0.43,
      height: MediaQuery.of(context).size.width * 0.20,
      margin: const EdgeInsets.all(10.0),
      padding: const EdgeInsets.all(20.0),
      decoration: BoxDecoration(
        color: const Color(0xD9111827),
        borderRadius: BorderRadius.circular(30)
      ),
    );
  }
}
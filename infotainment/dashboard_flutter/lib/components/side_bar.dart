import 'package:flutter/material.dart';

class SideBar extends StatelessWidget{
  const SideBar({super.key});

  @override
  Widget build(BuildContext context){
    return Container(
      color: const Color(0xFF111827),
      child:
        Column(
          children: [
            Container(
              padding: const EdgeInsets.all(20.0) ,
              child: const Column(
                children: [
                  Text("13:50", style: TextStyle(fontSize: 16, color: Colors.white, decoration: TextDecoration.none, fontWeight: FontWeight.w400),),
                  Text("14/05/2024", style: TextStyle(fontSize: 16, color: Colors.white, decoration: TextDecoration.none, fontWeight: FontWeight.w400))
                ]
              )
            ),
            Container()
          ]
        )
    );
  }
}
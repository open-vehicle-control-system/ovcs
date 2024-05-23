import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';

const String handBrakeIconPath = "assets/images/handbrake.svg";
final Widget handBrakeIcon = SvgPicture.asset(
  handBrakeIconPath,
  colorFilter: const ColorFilter.mode(Color(0XFF64748b), BlendMode.srcIn),
  height: 60,
  width: 60,
  semanticsLabel: 'Handbrake'
);

const String beamsIconPath = "assets/images/beams.svg";
final Widget beamsIcon = SvgPicture.asset(
  beamsIconPath,
  colorFilter: const ColorFilter.mode(Color(0XFF64748b), BlendMode.srcIn),
  height: 60,
  width: 60,
  semanticsLabel: 'Beams'
);

const String trunkPath = "assets/images/trunk.svg";
final Widget trunkIcon = SvgPicture.asset(
  trunkPath,
  colorFilter: const ColorFilter.mode(Color(0XFF64748b), BlendMode.srcIn),
  height: 60,
  width: 60,
  semanticsLabel: 'Trunk'
);

const String enginePath = "assets/images/engine.svg";
final Widget engineIcon = SvgPicture.asset(
  enginePath,
  colorFilter: const ColorFilter.mode(Color(0XFF64748b), BlendMode.srcIn),
  height: 60,
  width: 60,
  semanticsLabel: 'Trunk'
);

class CarOverview extends StatelessWidget {
  const CarOverview({super.key});

  @override
  Widget build(BuildContext context){
    return Container(
      width: MediaQuery.of(context).size.width * 0.37,
      height: MediaQuery.of(context).size.width * 0.32,
      margin: const EdgeInsets.all(10.0),
      padding: const EdgeInsets.all(20.0),
      decoration: BoxDecoration(
        color: const Color(0xD9111827),
        borderRadius: BorderRadius.circular(30)
      ),
      child: Column(children: [
        const Expanded(
          flex: 8,
          child: Row(
            children: [
              Expanded(
                child:
                  Image(
                    alignment: Alignment(1.0, 0.0),
                    image: AssetImage("assets/images/all_closed_left.png"))),
              Expanded(
                child:
                  Image(
                    alignment: Alignment(-1.0, 0.0),
                    image: AssetImage("assets/images/all_closed_right.png")))
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
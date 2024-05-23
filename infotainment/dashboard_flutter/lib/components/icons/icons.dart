import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:phoenix_socket/phoenix_socket.dart';


class OvcsIcons {
  static String handBrakeIconPath = "assets/images/handbrake.svg";
  static String beamsIconPath = "assets/images/beams.svg";
  static String trunkPath = "assets/images/trunk.svg";
  static String enginePath = "assets/images/engine.svg";

  static SvgPicture handBrakeOffSvg = SvgPicture.asset(
    handBrakeIconPath,
    colorFilter: const ColorFilter.mode(Color(0XFF64748b), BlendMode.srcIn),
    height: 60,
    width: 60,
    semanticsLabel: 'Handbrake off'
  );

 static SvgPicture handBrakeOnSvg = SvgPicture.asset(
    handBrakeIconPath,
    colorFilter: const ColorFilter.mode(Colors.amber, BlendMode.srcIn),
    height: 60,
    width: 60,
    semanticsLabel: 'Handbrake on'
  );

  static SvgPicture beamsOffSvg = SvgPicture.asset(
    beamsIconPath,
    colorFilter: const ColorFilter.mode(Color(0XFF64748b), BlendMode.srcIn),
    height: 60,
    width: 60,
    semanticsLabel: 'Beams off'
  );

  static SvgPicture beamsOnSvg = SvgPicture.asset(
    beamsIconPath,
    colorFilter: const ColorFilter.mode(Colors.lightBlue, BlendMode.srcIn),
    height: 60,
    width: 60,
    semanticsLabel: 'Beams on'
  );

  static SvgPicture trunkClosedSvg = SvgPicture.asset(
    trunkPath,
    colorFilter: const ColorFilter.mode(Color(0XFF64748b), BlendMode.srcIn),
    height: 60,
    width: 60,
    semanticsLabel: 'Trunk closed'
  );

  static SvgPicture trunkOpenSvg = SvgPicture.asset(
    trunkPath,
    colorFilter: const ColorFilter.mode(Colors.red, BlendMode.srcIn),
    height: 60,
    width: 60,
    semanticsLabel: 'Trunk open'
  );

  static SvgPicture engineOffSvg = SvgPicture.asset(
    enginePath,
    colorFilter: const ColorFilter.mode(Color(0XFF64748b), BlendMode.srcIn),
    height: 60,
    width: 60,
    semanticsLabel: 'Engine off'
  );

  static SvgPicture engineReadySvg = SvgPicture.asset(
    enginePath,
    colorFilter: const ColorFilter.mode(Colors.green, BlendMode.srcIn),
    height: 60,
    width: 60,
    semanticsLabel: 'Engine ready'
  );

  static SvgPicture toggleHandrakeIcon(Message event){
    if(event.payload?["handbrake_engaged"]){
      return OvcsIcons.handBrakeOnSvg;
    } else {
      return OvcsIcons.handBrakeOffSvg;
    }
  }

  static SvgPicture toggleBeamsIcon(Message event){
    if(event.payload?["beam_active"]){
      return OvcsIcons.beamsOnSvg;
    } else {
      return OvcsIcons.beamsOffSvg;
    }
  }

  static SvgPicture toggleTrunkIcon(Message event){
    if(event.payload?["trunk_door_open"]){
      return OvcsIcons.trunkOpenSvg;
    } else {
      return OvcsIcons.trunkClosedSvg;
    }
  }

  static SvgPicture toggleEngineIcon(Message event){
    if(event.payload?["ready_to_drive"]){
      return OvcsIcons.engineReadySvg;
    } else {
      return OvcsIcons.engineOffSvg;
    }
  }
}
import 'package:flutter/material.dart';
import 'package:phoenix_socket/phoenix_socket.dart';

class CarView{
    static const AssetImage allOpenLeft = AssetImage("assets/images/all_open_left.png");
    static const AssetImage frontOpenLeft = AssetImage("assets/images/front_left_open.png");
    static const AssetImage rearOpenLeft = AssetImage("assets/images/rear_left_open.png");
    static const AssetImage allClosedLeft = AssetImage("assets/images/all_closed_left.png");
    static const AssetImage allOpenRight = AssetImage("assets/images/all_open_right.png");
    static const AssetImage frontOpenRight = AssetImage("assets/images/front_right_open.png");
    static const AssetImage rearOpenRight = AssetImage("assets/images/rear_right_open.png");
    static const AssetImage allClosedRight = AssetImage("assets/images/all_closed_right.png");

    static AssetImage updateLeftView(Message event){
      var payload = event.payload;
      if(payload?["front_left_door_open"] && payload?["rear_left_door_open"]){
        return allOpenLeft;
      } else if(payload?["front_left_door_open"] && !payload?["rear_left_door_open"]){
        return frontOpenLeft;
      } else if(!payload?["front_left_door_open"] && payload?["rear_left_door_open"]){
        return rearOpenLeft;
      } else {
        return allClosedLeft;
      }
    }

    static AssetImage updateRightView(Message event){
      var payload = event.payload;
      if(payload?["front_right_door_open"] && payload?["rear_right_door_open"]){
        return allOpenRight;
      } else if(payload?["front_right_door_open"] && !payload?["rear_right_door_open"]){
        return frontOpenRight;
      } else if(!payload?["front_right_door_open"] && payload?["rear_right_door_open"]){
        return rearOpenRight;
      } else {
        return allClosedRight;
      }
    }
}
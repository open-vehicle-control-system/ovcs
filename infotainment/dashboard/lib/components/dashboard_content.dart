import 'package:flutter/material.dart';

import 'package:dashboard_flutter/components/battery_overview.dart';
import 'package:dashboard_flutter/components/car_overview.dart';
import 'package:dashboard_flutter/components/gear_selector.dart';
import 'package:dashboard_flutter/components/ovcs_status.dart';
import 'package:dashboard_flutter/components/speed_gauge.dart';

class DashboardContent extends StatelessWidget {
  const DashboardContent({super.key});

  @override
  Widget build(BuildContext context){
    return Expanded( child: Container(
      width: double.infinity,
      height: double.infinity,
      padding: const EdgeInsets.all(5.0),
      decoration: const BoxDecoration(
        image: DecorationImage(
          image: AssetImage("assets/images/launchpad_background.png"),
          fit: BoxFit.fill,
          repeat: ImageRepeat.noRepeat
        )
      ),
      child: const Column(
        children: [
          Row(
            children: [
              GearSelector(),
              SpeedGauge(),
              CarOverview()
            ]
          ),
          Row(
            children: [
              BatteryOverview(),
              OvcsStatus()
            ]
          )
        ]
      )
    ));
  }
}
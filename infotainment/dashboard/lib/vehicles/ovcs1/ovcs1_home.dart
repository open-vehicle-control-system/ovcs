import 'package:flutter/material.dart';

import 'package:dashboard_flutter/components/battery_overview.dart';
import 'package:dashboard_flutter/components/gear_selector.dart';
import 'package:dashboard_flutter/components/ovcs_status.dart';
import 'package:dashboard_flutter/components/gauge.dart';
import 'package:dashboard_flutter/vehicles/ovcs1/car_overview.dart';

class OVCS1Home extends StatelessWidget {
  const OVCS1Home({super.key});

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
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(
                width: MediaQuery.of(context).size.width * 0.10,
                height: MediaQuery.of(context).size.width * 0.39,
                child: const GearSelector(),
              ),
              Spacer(),
              SizedBox(
                width: MediaQuery.of(context).size.width * 0.39,
                height: MediaQuery.of(context).size.width * 0.39,
                child: const OVCSGauge(unit: "km/h", min: 0, max: 200, source: "speed"),
              ),
              Spacer(),
              SizedBox(
                width: MediaQuery.of(context).size.width * 0.39,
                height: MediaQuery.of(context).size.width * 0.39,
                child: const CarOverview(),
              ),
            ]
          ),
          Spacer(),
          Row(
            children: [
              Expanded(
                child: AspectRatio(
                  aspectRatio: 2.20,
                  child: const BatteryOverview(),
                ),
              ),
              Expanded(
                child: AspectRatio(
                  aspectRatio: 2.20,
                  child: const OvcsStatus(),
                ),
              ),
            ]
          )
        ]
      )
    ));
  }
}

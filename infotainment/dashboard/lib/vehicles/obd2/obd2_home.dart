import 'package:flutter/material.dart';
import 'package:dashboard_flutter/components/gauge.dart';

class OBD2Home extends StatelessWidget {
  const OBD2Home({super.key});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        width: double.infinity,
        height: double.infinity,
        padding: const EdgeInsets.all(5.0),
        decoration: const BoxDecoration(
          image: DecorationImage(
            image: AssetImage("assets/images/launchpad_background.png"),
            fit: BoxFit.fill,
            repeat: ImageRepeat.noRepeat,
          ),
        ),
        child: Column(
          children: [
            Row(
              children: [
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.44,
                  height: MediaQuery.of(context).size.width * 0.6,
                  child: const OVCSGauge(unit: "km/h", min: 0, max: 200, source: "speed"),
                ),
                Spacer(),
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.44,
                  height: MediaQuery.of(context).size.width * 0.6,
                  child: const OVCSGauge(unit: "rpm", min: 0, max: 10000, source: "rotation_per_minute"),
                ),
              ]
            ),
          ],
        ),
      ),
    );
  }
}

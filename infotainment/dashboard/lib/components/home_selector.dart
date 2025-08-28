import 'package:flutter/widgets.dart';
import 'package:dashboard_flutter/vehicles/stub/stub_home_selector.dart' as stub;
import 'package:dashboard_flutter/vehicles/ovcs1/ovcs1_home_selector.dart' as ovcs1;
import 'package:dashboard_flutter/vehicles/obd2/obd2_home_selector.dart' as obd2;

const String vehicleType = String.fromEnvironment('VEHICLE_TYPE');

Widget getHomeWidget() {
  switch (vehicleType) {
    case 'ovcs1':
      return ovcs1.getHomeWidget();
    case 'obd2':
      return obd2.getHomeWidget();
    default:
      return stub.getHomeWidget();
  }
}

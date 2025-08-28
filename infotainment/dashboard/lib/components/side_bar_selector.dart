import 'package:flutter/widgets.dart';
import 'package:dashboard_flutter/vehicles/stub/stub_side_bar_selector.dart' as stub;
import 'package:dashboard_flutter/vehicles/ovcs1/ovcs1_side_bar_selector.dart' as ovcs1;
import 'package:dashboard_flutter/vehicles/obd2/obd2_side_bar_selector.dart' as obd2;

const String vehicleType = String.fromEnvironment('VEHICLE_TYPE');

Widget getSidebarWidget() {
  switch (vehicleType) {
    case 'ovcs1':
      return ovcs1.getSidebarWidget();
    case 'obd2':
      return obd2.getSidebarWidget();
    default:
      return stub.getSidebarWidget();
  }
}

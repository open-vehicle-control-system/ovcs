defmodule InfotainmentApiWeb.Api.OVCS1.StatusJSON do
  use InfotainmentApiWeb, :view

  def render("status.json", status) do
    %{
      type: "status",
      id:    "status",
      attributes: %{
        selectedGear: status.selected_gear,
        frontLeftDoorOpen: status.front_left_door_open,
        frontRightDoorOpen: status.front_right_door_open,
        rearLeftDoorOpen: status.rear_left_door_open,
        rearRightDoorOpen: status.rear_right_door_open,
        trunkDoorOpen: status.trunk_door_open,
        beamActive: status.beam_active,
        handbrakeEngaged: status.handbrake_engaged,
        speed: status.speed,
        readyToDrive: status.ready_to_drive,
        inverterEnabled: status.inverter_enabled,
        mainNegativeContactorEnabled: status.main_negative_contactor_enabled,
        mainPositiveContactorEnabled: status.main_positive_contactor_enabled,
        prechargeContactorEnabled: status.precharge_contactor_enabled,
        vmsStatus: status.vms_computed_status,
        bmsStatus: status.bms_computed_status,
        frontControlerStatus: status.front_controler_computed_status,
        controlsControllerStatus: status.controls_controller_computed_status,
        rearControllerStatus: status.rear_controller_computed_status,
        packVoltage: status.pack_voltage,
        packStateOfCharge: status.pack_state_of_charge,
        packAverageTemperature: status.pack_average_temperature,
        packIsCharging: status.pack_is_charging,
        packCurrent: status.pack_current,
        twelveVoltBatteryStatus: status.twelve_volt_battery_status,
        j1772PlugState: status.j1772_plug_state
      }
    }
  end
end

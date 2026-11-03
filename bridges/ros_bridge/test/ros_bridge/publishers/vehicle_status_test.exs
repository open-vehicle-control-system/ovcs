defmodule RosBridge.Publishers.VehicleStatusTest do
  use ExUnit.Case, async: true

  alias Cantastic.Signal
  alias Ros2Zenoh.StdMsgs.Msg.{Bool, Float64}
  alias Ros2Zenoh.StdMsgs.Msg.String, as: RosString
  alias RosBridge.Publishers.VehicleStatus

  defp signals(values) do
    Map.new(values, fn {name, value} -> {name, %Signal{name: name, value: value}} end)
  end

  test "vms_status publishes the status and ready to drive" do
    assert [
             {"vms_status", RosString, %RosString{data: "OK"}},
             {"ready_to_drive", Bool, %Bool{data: true}}
           ] =
             VehicleStatus.messages(
               "vms_status",
               signals(%{"status" => "OK", "ready_to_drive" => true, "counter" => 3})
             )
  end

  test "gear_status publishes the gear" do
    assert [{"gear", RosString, %RosString{data: "reverse"}}] =
             VehicleStatus.messages("gear_status", signals(%{"selected_gear" => "reverse"}))
  end

  test "control_status publishes the level, commander, force and requests" do
    assert [
             {"control_level", RosString, %RosString{data: "ros"}},
             {"ros_commander", RosString, %RosString{data: "autonomous"}},
             {"control_level_forced", Bool, %Bool{data: false}},
             {"requested_throttle", Float64, %Float64{data: 0.25}},
             {"requested_steering", Float64, %Float64{data: -0.5}}
           ] =
             VehicleStatus.messages(
               "control_status",
               signals(%{
                 "control_level" => "ros",
                 "ros_commander" => "autonomous",
                 "control_level_forced" => false,
                 "requested_throttle" => Decimal.new("0.250"),
                 "requested_steering" => Decimal.new("-0.500")
               })
             )
  end

  test "Bool encodes as one byte" do
    assert Bool.encode(%Bool{data: true}) == <<1>>
    assert Bool.encode(%Bool{data: false}) == <<0>>
  end
end

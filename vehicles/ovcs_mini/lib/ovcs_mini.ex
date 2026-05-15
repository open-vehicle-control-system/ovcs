defmodule OvcsMini do
  @moduledoc """
  Top-level entry point for the OVCS Mini vehicle package.

  OVCS Mini has no infotainment side.
  """
  @behaviour OvcsVehicle
  @behaviour RosBridge

  @impl OvcsVehicle
  def name, do: "OVCS Mini"
  @impl OvcsVehicle
  def vms, do: OvcsMini.Vms.Composer
  @impl OvcsVehicle
  def can_config_otp_app, do: :ovcs_mini
  @impl OvcsVehicle
  def vms_target, do: :ovcs_base_can_system_rpi4

  @impl OvcsVehicle
  def bridge_firmwares do
    %{
      "radio_control" => %{
        target: :ovcs_base_can_system_rpi3a,
        bridges: [RadioControlBridge],
        default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:spi0.0"}
      },
      "ros" => %{
        target: :ovcs_base_can_system_rpi4,
        bridges: [RosBridge],
        default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:spi0.0"}
      }
    }
  end

  @impl RosBridge
  def ros_bridge_config do
    %RosBridge.Config{zenoh_endpoint_ip: "10.0.2.177"}
  end
end

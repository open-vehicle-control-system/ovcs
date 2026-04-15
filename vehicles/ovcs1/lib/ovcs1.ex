defmodule Ovcs1 do
  @moduledoc """
  Top-level entry point for the OVCS1 vehicle package.

  Links the VMS side (`Ovcs1.Vms`) and the infotainment side
  (`Ovcs1.Infotainment`) so consumers can dispatch through a single
  module reference.
  """
  @behaviour OvcsVehicle

  @impl OvcsVehicle
  def name, do: "OVCS1"
  @impl OvcsVehicle
  def vms, do: Ovcs1.Vms.Composer
  @impl OvcsVehicle
  def infotainment, do: Ovcs1.Infotainment.Composer
  @impl OvcsVehicle
  def can_config_otp_app, do: :ovcs1
  @impl OvcsVehicle
  def nerves_target(:vms), do: :ovcs_base_can_system_rpi4
  def nerves_target(:infotainment), do: :ovcs_base_can_system_rpi5

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
end

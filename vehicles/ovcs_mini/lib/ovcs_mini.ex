defmodule OvcsMini do
  @moduledoc """
  Top-level entry point for the OVCS Mini vehicle package.

  OVCS Mini has no infotainment side.
  """
  @behaviour OvcsVehicle

  @impl OvcsVehicle
  def name, do: "OVCSMini"
  @impl OvcsVehicle
  def vms, do: OvcsMini.Vms.Composer
  @impl OvcsVehicle
  def can_config_otp_app, do: :ovcs_mini
  @impl OvcsVehicle
  def nerves_target(:vms), do: :ovcs_base_can_system_rpi4

  @broker_host (if Mix.target() == :host, do: "localhost", else: "ovcs-mini-vms.local")

  @doc "Shared by composers + `OvcsVehicle.Bus.relay_opts/3`."
  def broker_host, do: @broker_host

  @impl OvcsVehicle
  def bridge_firmwares do
    %{
      "radio_control" => %{
        target: :ovcs_base_can_system_rpi3a,
        bridges: [RadioControlBridge],
        default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:spi0.0"},
        bus_relay: OvcsVehicle.Bus.relay_opts(__MODULE__, "ovcs-mini-bridge-radio_control")
      },
      "ros" => %{
        target: :ovcs_base_can_system_rpi4,
        bridges: [RosBridge],
        default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:spi0.0"},
        bus_relay: OvcsVehicle.Bus.relay_opts(__MODULE__, "ovcs-mini-bridge-ros")
      }
    }
  end
end

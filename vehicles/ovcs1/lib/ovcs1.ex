defmodule Ovcs1 do
  @moduledoc """
  Top-level entry point for the OVCS1 vehicle package.

  Links the VMS side (`Ovcs1.Vms`) and the infotainment side
  (`Ovcs1.Infotainment`) so consumers can dispatch through a single
  module reference.
  """
  @behaviour OvcsVehicle
  @behaviour RadioControlBridge
  @behaviour RosBridge

  @impl OvcsVehicle
  def name, do: "OVCS1"
  @impl OvcsVehicle
  def vms, do: Ovcs1.Vms.Composer
  @impl OvcsVehicle
  def infotainment, do: Ovcs1.Infotainment.Composer
  @impl OvcsVehicle
  def can_config_otp_app, do: :ovcs1
  @impl OvcsVehicle
  def vms_target, do: :ovcs_base_can_system_rpi4
  @impl OvcsVehicle
  def infotainment_target, do: :ovcs_base_can_system_rpi5

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

  @impl RadioControlBridge
  def radio_control_bridge_config(:host),
    do: %RadioControlBridge.Config{components: []}

  def radio_control_bridge_config(:target),
    do: %RadioControlBridge.Config{
      components: [
        {:mavlink_forwarder, uart_port: "ttySC0", uart_baud_rate: 460_800}
      ]
    }

  @impl RosBridge
  def ros_bridge_config(:host),
    do: %RosBridge.Config{
      zenoh_endpoint_ip: System.get_env("ZENOH_ENDPOINT_IP", "127.0.0.1"),
      components: [
        :heartbeat,
        :joy_interpreter,
        {:imu_publisher, driver: OvcsDrivers.Imu.Dummy}
      ]
    }

  def ros_bridge_config(:target),
    do: %RosBridge.Config{
      zenoh_endpoint_ip: Application.get_env(:ros_bridge, :zenoh_endpoint_ip, "127.0.0.1"),
      components: [
        :heartbeat,
        :joy_interpreter,
        {:imu_publisher, driver: BNO085.I2C}
      ]
    }
end

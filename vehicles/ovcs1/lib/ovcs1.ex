defmodule Ovcs1 do
  @moduledoc """
  Top-level entry point for the OVCS1 vehicle package.

  Links the VMS side (`Ovcs1.Vms`), the infotainment side
  (`Ovcs1.Infotainment`) and the vision unit (`Ovcs1.Vision`) so
  consumers can dispatch through a single module reference.
  """
  @behaviour OvcsVehicle
  @behaviour RadioControlBridge
  @behaviour RosBridge

  # The Volkswagen Polo 9N's published specifications, before its facelift.
  @wheelbase_m 2.46
  @front_track_m 1.435
  @rear_track_m 1.425
  @turning_circle_m 10.6
  # 185/60 R14 tyres.
  @tyre_width_mm 185
  @tyre_aspect_ratio 0.60
  @rim_diameter_inches 14
  @millimetres_per_inch 25.4

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
  def vision, do: Ovcs1.Vision.Composer
  @impl OvcsVehicle
  def vision_target, do: :arduino_ventuno_q

  @impl OvcsVehicle
  def geometry do
    %{
      wheelbase: @wheelbase_m,
      track: @rear_track_m,
      wheel_radius:
        (@rim_diameter_inches * @millimetres_per_inch + 2 * @tyre_width_mm * @tyre_aspect_ratio) /
          2 / 1000,
      steering_limit: steering_limit()
    }
  end

  # The bicycle model's angle that puts the outer front wheel on the turning circle.
  defp steering_limit do
    outer_front_radius = @turning_circle_m / 2

    rear_axle_radius =
      :math.sqrt(outer_front_radius ** 2 - @wheelbase_m ** 2) - @front_track_m / 2

    :math.atan(@wheelbase_m / rear_axle_radius)
  end

  @impl OvcsVehicle
  defdelegate simulator, to: Ovcs1.Simulator

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
        # MSP OSD path — declared but not enabled. Strip the leading
        # `# ` from the data line below and replace the UART with the
        # actual VTX serial line once `RadioControlBridge.MspOsdForwarder`
        # ships a real impl. (The leading comma is intentional so
        # enabling is a clean prefix removal — no other edits needed.)
        # , {:msp_osd_forwarder, uart_port: "ttyXXX", uart_baud_rate: 115_200}
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

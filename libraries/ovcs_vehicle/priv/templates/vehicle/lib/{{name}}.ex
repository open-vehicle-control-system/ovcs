defmodule <%= @module %> do
  @moduledoc """
  Top-level entry point for the <%= @display_name %> vehicle package.

  ## Geometry

  Declare `geometry/0` once something on the vehicle needs its shape,
  such as kinematics turning a velocity command into a steering angle.
  Measured values only, in metres and radians; see
  `t:OvcsVehicle.geometry/0`. If the vehicle also has a simulation
  model, test that the two agree, as
  `vehicles/ovcs_mini/test/geometry_test.exs` does.

      @impl OvcsVehicle
      def geometry,
        do: %{wheelbase: 0.0, track: 0.0, wheel_radius: 0.0, steering_limit: 0.0}
<%= if @bridges do %>
  ## Bridge firmwares

  Each entry of `bridge_firmwares/0` is a build target,
  `./ovcs build <%= @name %> bridge-<firmware-id>`, with its CAN topology in
  `priv/can/bridges/<firmware-id>.yml`. Both bridges start with no
  components; drop the entries your vehicle has no board for. See the
  [vehicle package guide](https://ovcs.be/docs/vehicle_package).
<% end %>  """
  @behaviour OvcsVehicle<%= if @bridges do %>
  @behaviour RadioControlBridge
  @behaviour RosBridge<% end %>

  @impl OvcsVehicle
  def name, do: "<%= @display_name %>"
  @impl OvcsVehicle
  def vms, do: <%= @module %>.Vms.Composer
<%= if @infotainment do %>  @impl OvcsVehicle
  def infotainment, do: <%= @module %>.Infotainment.Composer
<% end %>  @impl OvcsVehicle
  def can_config_otp_app, do: :<%= @name %>
  @impl OvcsVehicle
  def vms_target, do: :<%= @vms_target %>
<%= if @infotainment do %>  @impl OvcsVehicle
  def infotainment_target, do: :<%= @infotainment_target %>
<% end %><%= if @bridges do %>
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
  def radio_control_bridge_config(_arm), do: %RadioControlBridge.Config{components: []}

  @impl RosBridge
  def ros_bridge_config(:host),
    do: %RosBridge.Config{
      zenoh_endpoint_ip: System.get_env("ZENOH_ENDPOINT_IP", "127.0.0.1"),
      components: [:heartbeat]
    }

  def ros_bridge_config(:target),
    do: %RosBridge.Config{
      zenoh_endpoint_ip: Application.get_env(:ros_bridge, :zenoh_endpoint_ip, "127.0.0.1"),
      components: [:heartbeat]
    }
<% end %>end

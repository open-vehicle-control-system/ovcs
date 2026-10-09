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
  `./ovcs build <%= @name %> bridge-<firmware-id>`, and each bundled bridge
  needs its configuration callback on this module. A radio-control
  bridge also needs `priv/can/bridges/radio_control.yml`; start from the
  OVCS Mini reference vehicle's. See the
  [vehicle package guide](https://ovcs.be/docs/vehicle_package).

      @behaviour RadioControlBridge

      @impl OvcsVehicle
      def bridge_firmwares do
        %{
          "radio_control" => %{
            target: :ovcs_base_can_system_rpi3a,
            bridges: [RadioControlBridge],
            default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:spi0.0"}
          }
        }
      end

      @impl RadioControlBridge
      def radio_control_bridge_config(:host),
        do: %RadioControlBridge.Config{components: []}

      def radio_control_bridge_config(:target),
        do: %RadioControlBridge.Config{
          components: [{:mavlink_forwarder, uart_port: "ttySC0", uart_baud_rate: 460_800}]
        }
<% end %>  """
  @behaviour OvcsVehicle

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
<% end %>end

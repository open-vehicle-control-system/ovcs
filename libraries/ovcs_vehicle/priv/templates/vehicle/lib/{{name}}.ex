defmodule <%= @module %> do
  @moduledoc """
  Top-level entry point for the <%= @display_name %> vehicle package.
  """
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
<% end %>
  # Measured physical geometry — optional, in **metres and radians**.
  #
  # Declare it if anything on this vehicle needs to know its shape.
  # Kinematics is the case that forces it: turning a velocity command
  # into a steering angle is the same arithmetic on every Ackermann
  # vehicle and a different number on each one, so `vms_core` stays
  # generic and takes these as composer options.
  #
  # Only measured quantities go here. Derived ones are functions —
  # `OvcsVehicle.min_turning_radius/1`, `max_yaw_rate/2` — because a
  # stored derived value is one more copy to get wrong.
  #
  # If this vehicle also has a simulation model, the same numbers live
  # in its xacro and cannot be shared, so add a test asserting the two
  # agree. See `vehicles/ovcs_mini/test/geometry_test.exs`; a wheel
  # radius wrong by 2x shipped in that model once.
  #
  # @impl OvcsVehicle
  # def geometry,
  #   do: %{
  #     wheelbase: 0.0,
  #     track: 0.0,
  #     wheel_radius: 0.0,
  #     steering_limit: 0.0
  #   }
<%= if @bridges do %>
  # Bridge firmwares — optional. Uncomment and populate to declare one
  # or more bridge firmware images for this vehicle. Each entry becomes
  # its own build target: `./ovcs build <%= @name %> bridge-<firmware-id>`.
  # The shared `bridges/firmware` image reads VEHICLE +
  # BRIDGE_FIRMWARE_ID at boot and supervises only the bridges listed.
  #
  # Some bridges expose their own behaviour for per-vehicle config — e.g.
  # bundling `RosBridge` also requires `@behaviour RosBridge` on this
  # module + a `ros_bridge_config/0` callback returning a
  # `%RosBridge.Config{}`. See `vehicles/ovcs_mini/lib/ovcs_mini.ex` and
  # `vehicles/ovcs1/lib/ovcs1.ex` for the pattern.
  #
  # @impl OvcsVehicle
  # def bridge_firmwares do
  #   %{
  #     "radio_control" => %{
  #       target: :ovcs_base_can_system_rpi3a,
  #       bridges: [RadioControlBridge],
  #       default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:spi0.0"}
  #       # can_config_path: "can/bridges/radio_control.yml"  # optional override
  #     }
  #   }
  # end
<% end %>end

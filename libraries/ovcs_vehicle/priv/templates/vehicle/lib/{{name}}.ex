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
<% end %><%= if @bridges do %>
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

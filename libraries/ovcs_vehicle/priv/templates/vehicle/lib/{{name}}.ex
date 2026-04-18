defmodule <%= @module %> do
  @moduledoc """
  Top-level entry point for the <%= @upper %> vehicle package.
  """
  @behaviour OvcsVehicle

  @impl OvcsVehicle
  def name, do: "<%= @upper %>"
  @impl OvcsVehicle
  def vms, do: <%= @module %>.Vms.Composer
<%= if @infotainment do %>  @impl OvcsVehicle
  def infotainment, do: <%= @module %>.Infotainment.Composer
<% end %>  @impl OvcsVehicle
  def can_config_otp_app, do: :<%= @name %>
  @impl OvcsVehicle
  def nerves_target(:vms), do: :<%= @vms_target %>
<%= if @infotainment do %>  def nerves_target(:infotainment), do: :<%= @infotainment_target %>
<% end %>
  # MQTT broker lives on the VMS firmware. Host dev splits into
  # multiple BEAMs on the same machine, so peers connect to
  # `localhost`; on Nerves each firmware is its own device and peers
  # reach the VMS via mDNS.
  @broker_host (if Mix.target() == :host, do: "localhost", else: "<%= @name %>-vms.local")

  @doc false
  def broker_host, do: @broker_host

  # Bridge firmwares — optional. Uncomment and populate to declare one
  # or more bridge firmware images for this vehicle. Each entry becomes
  # its own build target: `./ovcs build <%= @name %> <firmware-id>`.
  # The shared `bridges/firmware` image reads VEHICLE +
  # BRIDGE_FIRMWARE_ID at boot and supervises only the bridges listed.
  #
  # @impl OvcsVehicle
  # def bridge_firmwares do
  #   %{
  #     "radio_control" => %{
  #       target: :ovcs_base_can_system_rpi3a,
  #       bridges: [RadioControlBridge],
  #       default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:spi0.0"},
  #       # can_config_path: "can/bridges/radio_control.yml",  # optional override
  #       bus_relay: %{
  #         broker: [host: @broker_host, port: 1884],
  #         client_id: "<%= @name %>-bridge-radio_control",
  #         topic_prefix: "ovcs/<%= @name %>/bus"
  #       }
  #     }
  #   }
  # end
end

defmodule <%= @module %>.Vms.Composer do
  @moduledoc """
  Wires up the VMS supervision tree, CAN config, dashboard, and
  generic_controller map for `<%= @upper %>`.

  This is the main place you'll edit as the vehicle gains real
  hardware. `children/0` is the supervision tree — add a child spec
  for each physical component (inverter, BMS, steering column, …)
  and pair it with matching CAN YAMLs under `priv/can/`.
  """
  @behaviour VmsCore.Vehicle

  alias VmsCore.Components.OVCS
  alias <%= @module %>.Vms

  @impl VmsCore.Vehicle
  defdelegate generic_controllers, to: <%= @module %>.Vms.Composer.GenericController
  @impl VmsCore.Vehicle
  defdelegate dashboard_configuration, to: <%= @module %>.Vms.Composer.Dashboard

  @impl VmsCore.Vehicle
  def can_config_otp_app, do: :<%= @name %>
  @impl VmsCore.Vehicle
  def can_config_path, do: "can/vms.yml"

  @impl VmsCore.Vehicle
  def default_can_mapping(:host), do: "ovcs:vcan0"
  def default_can_mapping(:target), do: "ovcs:spi0.0"

  # Optional — host the MQTT broker for the vehicle. Requires the
  # mosquitto binary in the Nerves rootfs; see OvcsBus.Broker.
  #
  # @impl VmsCore.Vehicle
  # def bus_broker do
  #   %{port: 1884}
  # end

  # Optional — relay selected bus messages to an MQTT broker so the
  # VMS, infotainment, and bridge firmwares share one logical bus.
  # Uncomment once the broker is reachable (hosted above or external).
  #
  # @impl VmsCore.Vehicle
  # def bus_relay do
  #   %{
  #     broker: [host: "<%= @name %>-vms.local", port: 1884],
  #     client_id: "<%= @name %>-vms",
  #     topic_prefix: "ovcs/<%= @name %>/bus",
  #     topics: [:ready_to_drive, :vms_status]
  #   }
  # end

  @impl VmsCore.Vehicle
  def children do
    [
      # Example generic_controller: a board on the CAN bus with
      # digital + analog pins. Rename / duplicate for each physical
      # controller you run (see priv/can/generic_controller/).
      %{
        id: Vms.ExampleController,
        start:
          {OVCS.GenericController, :start_link,
           [
             %{
               process_name: Vms.ExampleController,
               control_digital_pins: false,
               control_other_pins: false,
               enabled_external_pwms: []
             }
           ]}
      },

      # Broadcasts VMS status/reset events — required by `Vms`.
      {VmsCore.Status,
       %{
         ready_to_drive_source: Vms,
         vms_status_source: Vms
       }},

      # Your vehicle's GenServer — put vehicle-specific state and
      # bus-driven logic in `<%= @module %>.Vms`.
      {Vms, []}
    ]
  end
end

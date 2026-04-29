defmodule <%= @module %>.Vms.Composer do
  @moduledoc """
  Wires up the VMS supervision tree, CAN config, dashboard, and
  generic_controller map for `<%= @display_name %>`.

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

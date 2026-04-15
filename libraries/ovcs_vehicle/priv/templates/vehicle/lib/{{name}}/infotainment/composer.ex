defmodule <%= @module %>.Infotainment.Composer do
  @moduledoc """
  Wires up the infotainment supervision tree, CAN config, and UI
  layout for `<%= @upper %>`.
  """
  @behaviour InfotainmentCore.Vehicle

  @impl InfotainmentCore.Vehicle
  defdelegate infotainment_configuration, to: <%= @module %>.Infotainment.Composer.Infotainment

  @impl InfotainmentCore.Vehicle
  def can_config_otp_app, do: :<%= @name %>
  @impl InfotainmentCore.Vehicle
  def can_config_path, do: "can/infotainment.yml"

  @impl InfotainmentCore.Vehicle
  def default_can_mapping(:host), do: "ovcs:vcan0"
  def default_can_mapping(:target), do: "ovcs:can0"

  @impl InfotainmentCore.Vehicle
  def children do
    [
      {<%= @module %>.Infotainment, []}
    ]
  end

  # Optional — same broker as the VMS side so both firmwares share
  # the bus feed. Uncomment once the broker is running.
  #
  # @impl InfotainmentCore.Vehicle
  # def bus_relay do
  #   %{
  #     broker: [host: "<%= @name %>-vms.local", port: 1884],
  #     client_id: "<%= @name %>-infotainment",
  #     topic_prefix: "ovcs/<%= @name %>/bus",
  #     topics: [:ready_to_drive, :vms_status]
  #   }
  # end
end

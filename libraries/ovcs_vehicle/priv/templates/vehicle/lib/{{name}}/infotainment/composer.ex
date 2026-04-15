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
end

defmodule Ovcs1.Infotainment.Composer do
  @moduledoc """
    Compose the infotainment configuration for the OVCS1 vehicle
  """
  @behaviour InfotainmentCore.Vehicle

  alias Ovcs1.Infotainment

  @impl InfotainmentCore.Vehicle
  defdelegate infotainment_configuration, to: Infotainment.Composer.Infotainment

  @impl InfotainmentCore.Vehicle
  def can_config_otp_app, do: :ovcs1
  @impl InfotainmentCore.Vehicle
  def can_config_path, do: "can/infotainment.yml"

  @impl InfotainmentCore.Vehicle
  def default_can_mapping(:host), do: "ovcs:vcan1"
  def default_can_mapping(:target), do: "ovcs:can0"

  @impl InfotainmentCore.Vehicle
  def children do
    [
      {Ovcs1.Infotainment, []}
    ]
  end

  @impl InfotainmentCore.Vehicle
  def bus_relay do
    OvcsVehicle.Bus.relay_opts(Ovcs1, "ovcs1-infotainment",
      topics: [:ready_to_drive, :vms_status, :selected_gear, :speed]
    )
  end
end

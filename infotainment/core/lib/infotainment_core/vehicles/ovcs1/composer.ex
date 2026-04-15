defmodule InfotainmentCore.Vehicles.OVCS1.Composer do
  @moduledoc """
    Compose the infotainment configuration for the OVCS1 vehicle
  """
  @behaviour InfotainmentCore.Vehicle

  alias InfotainmentCore.Vehicles.OVCS1

  @impl InfotainmentCore.Vehicle
  defdelegate infotainment_configuration, to: OVCS1.Composer.Infotainment

  @impl InfotainmentCore.Vehicle
  def can_config_otp_app, do: :infotainment_core
  @impl InfotainmentCore.Vehicle
  def can_config_path, do: "ovcs1.yml"

  @impl InfotainmentCore.Vehicle
  def children do
    [
      {InfotainmentCore.Vehicles.OVCS1, []}
    ]
  end
end

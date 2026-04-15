defmodule InfotainmentCore.Vehicles.OBD2.Composer do
  @moduledoc """
    Compose the infotainment configuration for a basic OBD2 vehicle
  """
  @behaviour InfotainmentCore.Vehicle

  alias InfotainmentCore.Vehicles.OBD2

  @impl InfotainmentCore.Vehicle
  defdelegate infotainment_configuration, to: OBD2.Composer.Infotainment

  @impl InfotainmentCore.Vehicle
  def children do
    [
      {InfotainmentCore.Vehicles.OBD2, []}
    ]
  end
end

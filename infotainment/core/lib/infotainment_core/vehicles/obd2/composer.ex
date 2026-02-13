defmodule InfotainmentCore.Vehicles.OBD2.Composer do
  @moduledoc """
    Compose the infotainment configuration for a basic OBD2 vehicle
  """

  alias InfotainmentCore.Vehicles.OBD2

  defdelegate infotainment_configuration, to: OBD2.Composer.Infotainment

  def children do
    [
      {InfotainmentCore.Vehicles.OBD2, []}
    ]
  end
end

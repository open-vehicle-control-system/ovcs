defmodule InfotainmentCore.Vehicles.OVCS1.Composer do
  @moduledoc """
    Compose the infotainment configuration for the OVCS1 vehicle
  """

  alias InfotainmentCore.Vehicles.OVCS1

  defdelegate infotainment_configuration, to: OVCS1.Composer.Infotainment

  def children do
    [
      {InfotainmentCore.Vehicles.OVCS1, []}
    ]
  end
end

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
  def children do
    [
      {Ovcs1.Infotainment, []}
    ]
  end
end

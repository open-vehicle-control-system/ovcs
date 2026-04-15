defmodule Obd2.Infotainment.Composer do
  @moduledoc """
    Compose the infotainment configuration for a basic OBD2 vehicle
  """
  @behaviour InfotainmentCore.Vehicle

  alias Obd2.Infotainment

  @impl InfotainmentCore.Vehicle
  defdelegate infotainment_configuration, to: Infotainment.Composer.Infotainment

  @impl InfotainmentCore.Vehicle
  def can_config_otp_app, do: :obd2
  @impl InfotainmentCore.Vehicle
  def can_config_path, do: "can/infotainment.yml"

  @impl InfotainmentCore.Vehicle
  def children do
    [
      {Obd2.Infotainment, []}
    ]
  end
end

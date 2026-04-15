defmodule VmsCore.Vehicles.OBD2.Composer do
  @moduledoc """
    Combine all the modules require to run the OBD2 connector
  """
  @behaviour VmsCore.Vehicle

  alias VmsCore.Vehicles

  @impl VmsCore.Vehicle
  defdelegate dashboard_configuration, to:  Vehicles.OBD2.Composer.Dashboard

  @impl VmsCore.Vehicle
  def can_config_otp_app, do: :vms_core
  @impl VmsCore.Vehicle
  def can_config_path, do: "can/vehicles/obd2.yml"

  @impl VmsCore.Vehicle
  def children do
    [
      {Vehicles.OBD2, []}
    ]
  end

  @impl VmsCore.Vehicle
  def generic_controllers do
    %{}
  end
end

defmodule Obd2.Vms.Composer do
  @moduledoc """
    Combine all the modules require to run the OBD2 connector
  """
  @behaviour VmsCore.Vehicle

  alias Obd2.Vms

  @impl VmsCore.Vehicle
  defdelegate dashboard_configuration, to:  Obd2.Vms.Composer.Dashboard

  @impl VmsCore.Vehicle
  def can_config_otp_app, do: :obd2
  @impl VmsCore.Vehicle
  def can_config_path, do: "can/vms.yml"

  @impl VmsCore.Vehicle
  def children do
    [
      {Vms, []}
    ]
  end

  @impl VmsCore.Vehicle
  def generic_controllers do
    %{}
  end
end

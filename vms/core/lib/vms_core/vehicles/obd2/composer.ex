defmodule VmsCore.Vehicles.OBD2.Composer do
  @moduledoc """
    Combine all the modules require to run the OBD2 connector
  """

  alias VmsCore.Vehicles

  defdelegate dashboard_configuration, to:  Vehicles.OBD2.Composer.Dashboard

  def children do
    [
      # Vehicle
      {VmsCore.Components.OBD2.Status, []},
      {Vehicles.OBD2, []},
    ]
  end

  def generic_controllers do
    %{}
  end
end

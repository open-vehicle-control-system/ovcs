defmodule VmsCore.Vehicles.OBD2.Composer do
  @moduledoc """
  OBD2 vehicle composer — wires up the diagnostic GenServers and the
  dashboard configuration so the standard composer dispatch
  (`VmsCore.Application.vehicle_composer/0`) picks them up.
  """

  alias VmsCore.Vehicles.OBD2

  defdelegate dashboard_configuration, to: OBD2.Composer.Dashboard

  def children do
    [
      {OBD2.Diagnostics, []},
      {OBD2.Discovery, []}
    ]
  end

  def generic_controllers do
    %{}
  end
end

defmodule VmsCore.Vehicles.OBD2.Composer do
  @moduledoc """
    Combine all the modules require to run the OBD2 connector
  """

  alias VmsCore.Vehicles

  defdelegate dashboard_configuration, to:  Vehicles.OBD2.Composer.Dashboard

  def children do
    [
      %{
        id: VmsCore.Vehicles.OBD2.Request,
        start: {
          Cantastic.ISOTPRequest,
          :start_link, [%{
            process_name: VmsCore.Vehicles.OBD2.Request,
            can_interface: "can1",
            request_frame_id: 0x7DF,
            response_frame_id: 0x7E8
          }]
        }
      },
      # Vehicle
      {Vehicles.OBD2, []},
    ]
  end

  def generic_controllers do
    %{}
  end
end

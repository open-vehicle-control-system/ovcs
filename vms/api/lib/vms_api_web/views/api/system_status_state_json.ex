defmodule VmsApiWeb.Api.SystemStatusStateJSON do
  use VmsApiWeb, :view

  def render("system_status_state.json", %{vehicle_status: vehicle_status}) do
    %{
      type: "systemStatusState",
      id:    "systemStatusState",
      attributes: %{
        failedEmitters: Enum.map(vehicle_status.failed_frames, fn {_, emitter_object} ->
          emitter_object.emitter
        end
        )
      }
    }
  end
end

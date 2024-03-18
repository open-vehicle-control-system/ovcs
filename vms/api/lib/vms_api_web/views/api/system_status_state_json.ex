defmodule VmsApiWeb.Api.SystemStatusStateJSON do
  use VmsApiWeb, :view

  def render("system_status_state.json", %{failed_frames: failed_frames}) do
    %{
      type: "systemStatusState",
      id:    "systemStatusState",
      attributes: %{
        failedEmitters: Enum.map(failed_frames, fn {_, emitter_object} ->
          emitter_object.emitter
        end
        )
      }
    }
  end
end

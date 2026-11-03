defmodule VisionApiWeb.ExporterController do
  @moduledoc """
  What takes the unit's outputs out of it, read-only: its exporters
  (`VisionCore.Exporters.list/1`), then the API itself, which is
  answering, as `exporters`.
  """
  use VisionApiWeb, :controller

  # What the channels carry, through the previews, the status and the detections.
  @channel_outputs [{:camera_frame, :left}, {:camera_frame, :right}, :stereo_pair, :detections]

  def index(conn, _params),
    do: render(conn, :index, exporters: VisionCore.Exporters.list() ++ [api()])

  defp api do
    %{
      id: "api",
      name: "API",
      module: VisionApiWeb.Endpoint,
      status: {:ok, "Answering"},
      outputs:
        for(
          output <- @channel_outputs,
          VisionCore.Exporter.output_key(output) != nil,
          do: %{output: output, max_hz: nil}
        )
    }
  end
end

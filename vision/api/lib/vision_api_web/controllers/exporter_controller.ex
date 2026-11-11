defmodule VisionApiWeb.ExporterController do
  @moduledoc """
  What takes the unit's outputs out of it, read-only: its exporters
  (`VisionCore.Exporters.list/1`), then the API itself, which is
  answering, as `exporters`. The API's outputs are those its channels
  carry, each with the most values a channel carries a second: the
  previews' rate (`VisionCore.Preview.options/0`) for the camera frames
  and each pair's depth, and then each detection pipeline's detections,
  in the order of the configuration's detectors: `:detections` for the
  default pipeline and `{:detections, name}` for a named one, each at
  its pipeline's `VisionCore.Detection.Live.max_hz/1`.
  """
  use VisionApiWeb, :controller

  @preview_outputs [{:camera_frame, :left}, {:camera_frame, :right}, :stereo_pair]

  def index(conn, _params),
    do: render(conn, :index, exporters: VisionCore.Exporters.list() ++ [api()])

  defp api do
    config = VisionCore.Application.active_config()
    outputs = Enum.filter(@preview_outputs, &VisionCore.Exporter.output_key(&1, config))

    %{
      id: "api",
      name: "API",
      module: VisionApiWeb.Endpoint,
      status: {:ok, "Answering"},
      outputs:
        Enum.map(
          outputs ++ detection_outputs(config),
          &%{output: &1, max_hz: channel_max_hz(&1)}
        ),
      actions: []
    }
  end

  defp detection_outputs(nil), do: []

  defp detection_outputs(config),
    do: for({output, _key} <- VisionCore.Detection.Supervisor.outputs(config), do: output)

  # A channel whose process is not running carries nothing to bound.
  defp channel_max_hz(:detections), do: call_or_nil(&VisionCore.Detection.Live.max_hz/0)

  defp channel_max_hz({:detections, name}),
    do: call_or_nil(fn -> VisionCore.Detection.Live.max_hz(name) end)

  defp channel_max_hz(_preview_output), do: call_or_nil(&preview_max_hz/0)

  defp preview_max_hz, do: VisionCore.Preview.options().max_hz

  defp call_or_nil(fun) do
    fun.()
  catch
    :exit, _reason -> nil
  end
end

defmodule VisionApiWeb.ExporterController do
  @moduledoc """
  What takes the unit's outputs out of it, read-only: its exporters
  (`VisionCore.Exporters.list/1`), then the API itself, which is
  answering, as `exporters`. The API's outputs are those its channels
  carry, each with the most values a channel carries a second: the
  previews' rate (`VisionCore.Preview.options/0`) for the camera frames
  and each pair's depth, `{:camera_frame, name}` for each camera of its
  own, in the order of the configuration's cameras, then
  `{:camera_video, name, output}` for each camera video
  `VisionCore.Video` relays, every frame, unbounded, and then each
  detection pipeline's detections, `{:detections, name}`, in the order
  of the configuration's detectors, each at
  its pipeline's `VisionCore.Detection.Live.max_hz/1` and with its
  source, the preview its boxes are drawn on: `"left"` for the stereo
  pair, the camera's name for a camera of its own; then each
  segmentation pipeline's `{:segmentation, name}`, in the order of the
  configuration's segmenters, at its pipeline's
  `VisionCore.Segmentation.Live.max_hz/1` and with its camera's name as
  its source, but for a pipeline given no camera, which never runs.
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
        Enum.map(outputs ++ camera_outputs(config), &%{output: &1, max_hz: channel_max_hz(&1)}) ++
          video_outputs() ++ detection_outputs(config) ++ segmentation_outputs(config),
      actions: []
    }
  end

  defp camera_outputs(nil), do: []

  defp camera_outputs(config),
    do: for({output, _key} <- VisionCore.Camera.Unit.outputs(config), do: output)

  defp video_outputs do
    for {camera, output} <- call_or_nil(&VisionCore.Video.videos/0) || [],
        do: %{output: {:camera_video, camera, output}, max_hz: nil}
  end

  defp detection_outputs(nil), do: []

  defp detection_outputs(config) do
    for {output, source} <- VisionCore.Detection.Supervisor.sources(config),
        do: %{output: output, max_hz: channel_max_hz(output), source: source_name(source)}
  end

  defp segmentation_outputs(nil), do: []

  defp segmentation_outputs(config) do
    for {name, camera} <- VisionCore.Segmentation.Supervisor.cameras(config) do
      output = VisionCore.Segmentation.output(name)
      %{output: output, max_hz: channel_max_hz(output), source: Atom.to_string(camera)}
    end
  end

  defp source_name(:stereo), do: "left"
  defp source_name({:camera, name}), do: Atom.to_string(name)
  defp source_name({:camera, name, _output}), do: Atom.to_string(name)

  # A channel whose process is not running carries nothing to bound.
  defp channel_max_hz({:detections, name}),
    do: call_or_nil(fn -> VisionCore.Detection.Live.max_hz(name) end)

  defp channel_max_hz({:segmentation, name}),
    do: call_or_nil(fn -> VisionCore.Segmentation.Live.max_hz(name) end)

  defp channel_max_hz(_preview_output), do: call_or_nil(&preview_max_hz/0)

  defp preview_max_hz, do: VisionCore.Preview.options().max_hz

  defp call_or_nil(fun) do
    fun.()
  catch
    :exit, _reason -> nil
  end
end

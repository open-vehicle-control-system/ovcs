defmodule VisionApiWeb.ExporterController do
  @moduledoc """
  What takes the unit's outputs out of it, read-only: its exporters
  (`VisionCore.Exporters.describe/0`), then the API itself, which is
  answering, as `exporters`. Their statuses come with the unit's status
  (`VisionApiWeb.StatusJSON`). The API's outputs are those its channels
  carry, each with the most values a channel carries a second: the
  previews' rate (`VisionCore.Preview.options/0`) for the stereo unit's
  frames, `{:stereo_frame, side}`, and each pair's depth, then
  `{:camera_frame, name}` for each camera of its own, in the order of
  the configuration's cameras, each with its source, the preview stream
  it is shown on (`VisionCore.Preview.streams/1`); then
  `{:camera_video, name, output}` for each camera video
  `VisionCore.Video` relays, every frame, unbounded, and then each
  detection pipeline's detections, `{:detections, name}`, in the order
  of the configuration's detectors, each at
  its pipeline's `VisionCore.Detection.Live.max_hz/1` and with its
  source, the preview its boxes are drawn on: the stereo unit's left
  camera's, `<prefix>/left`, for the stereo pair, the camera's name for
  a camera of its own; then each
  segmentation pipeline's `{:segmentation, name}`, in the order of the
  configuration's segmenters, at its pipeline's
  `VisionCore.Segmentation.Live.max_hz/1` and with its camera's name as
  its source, but for a pipeline given no camera, which never runs.
  """
  use VisionApiWeb, :controller

  def index(conn, _params),
    do: render(conn, :index, exporters: VisionCore.Exporters.describe() ++ [api()])

  defp api do
    config = VisionCore.Application.active_config()

    %{
      id: VisionApiWeb.Exporter.api_entry().id,
      name: VisionApiWeb.Exporter.api_entry().name,
      module: VisionApiWeb.Endpoint,
      outputs:
        preview_outputs(config) ++
          video_outputs() ++ detection_outputs(config) ++ segmentation_outputs(config),
      actions: []
    }
  end

  defp preview_outputs(nil), do: []

  defp preview_outputs(config) do
    [left, right, depth | _cameras] = VisionCore.Preview.streams(config)

    stereo =
      Enum.filter(
        [{{:stereo_frame, :left}, left}, {{:stereo_frame, :right}, right}, {:stereo_pair, depth}],
        fn {output, _stream} -> VisionCore.Exporter.output_key(output, config) end
      )

    cameras =
      for {{:camera_frame, name} = output, _key} <- VisionCore.Camera.Unit.outputs(config),
          do: {output, Atom.to_string(name)}

    for {output, stream} <- stereo ++ cameras,
        do: %{output: output, max_hz: channel_max_hz(output), source: stream}
  end

  defp video_outputs do
    for {camera, output} <- call_or_nil(&VisionCore.Video.videos/0) || [],
        do: %{output: {:camera_video, camera, output}, max_hz: nil}
  end

  defp detection_outputs(nil), do: []

  defp detection_outputs(config) do
    for {output, source} <- VisionCore.Detection.Supervisor.sources(config),
        do: %{output: output, max_hz: channel_max_hz(output), source: source_name(source, config)}
  end

  defp segmentation_outputs(nil), do: []

  defp segmentation_outputs(config) do
    for {name, camera} <- VisionCore.Segmentation.Supervisor.cameras(config) do
      output = VisionCore.Segmentation.output(name)
      %{output: output, max_hz: channel_max_hz(output), source: Atom.to_string(camera)}
    end
  end

  defp source_name(:stereo, config),
    do: Keyword.fetch!(VisionCore.Stereo.Supervisor.labels(config), :left)

  defp source_name({:camera, name}, _config), do: Atom.to_string(name)
  defp source_name({:camera, name, _output}, _config), do: Atom.to_string(name)

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

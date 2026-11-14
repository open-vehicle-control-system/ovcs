defmodule VisionCore.Ros2.BagExporter.Preset do
  @moduledoc """
  What a recording of `VisionCore.Ros2.BagExporter` holds: the options of
  the `VisionCore.Ros2.ZenohExporter` that builds its messages, from the
  configuration alone, so they name what it has and no camera or pipeline
  of a vehicle.

    * **replay** — each stereo side's frames uncompressed, `mono8` on
      `<prefix>/<side>/image_raw`, with its camera info, none of the pairs'
      messages; each camera's image as it delivered it, its first JPEG
      output when it has one, else its default output encoded to JPEG,
      with its camera info; the cameras' poses on `/tf_static`. What
      `ros2 bag play` feeds a stereo pipeline off the unit.
    * **review** — the stereo left image compressed, the pairs' depth and
      its camera info; each camera's image and camera info as in replay;
      every detection pipeline's and every segmentation pipeline's results;
      the cameras' poses. What a drive is looked at with, hours long.

  A part the configuration lacks, such as a stereo unit, is left out.
  """

  alias VisionCore.Camera.{Output, Unit}
  alias VisionCore.Detection.Supervisor, as: DetectionSupervisor
  alias VisionCore.Segmentation.Supervisor, as: SegmentationSupervisor
  alias VisionCore.Stereo.Supervisor, as: StereoSupervisor

  @type name :: :replay | :review

  @names [:replay, :review]

  @doc "The presets, in the order they are listed."
  @spec names() :: [name()]
  def names, do: @names

  @doc """
  The `VisionCore.Ros2.ZenohExporter` options of the preset `name` on
  `config`; see the module doc. It reads no file: `VisionCore.Exporters`
  lists the bag exporter's outputs every second.
  """
  @spec options(name(), VisionCore.Config.t()) :: keyword()
  def options(:replay, config) do
    stereo(config, raw_images: true, publish_raw_images: false, pair_messages: []) ++
      cameras(config)
  end

  def options(:review, config) do
    stereo(config, sides: [:left], pair_messages: [:depth]) ++
      cameras(config) ++ detections(config) ++ segmentation(config)
  end

  defp stereo(config, options),
    do: if(StereoSupervisor.outputs(config) == [], do: [], else: [stereo: options])

  defp cameras(config) do
    case Unit.cameras(config) do
      [] ->
        []

      cameras ->
        jpeg_outputs =
          for {name, _driver, _server} <- cameras,
              output = jpeg_output(config, name),
              do: {name, output}

        [cameras: if(jpeg_outputs == [], do: [], else: [outputs: jpeg_outputs])]
    end
  end

  defp jpeg_output(config, name) do
    case Unit.camera_outputs(config, name) do
      {:ok, outputs} when is_list(outputs) ->
        Enum.find_value(Output.images(outputs), &(&1.format == :jpeg and &1.name))

      _no_named_outputs ->
        nil
    end
  end

  defp detections(config) do
    case for({{:detections, name}, _source} <- DetectionSupervisor.sources(config), do: name) do
      [] -> []
      pipelines -> [detections: [pipelines: pipelines]]
    end
  end

  defp segmentation(config),
    do: if(SegmentationSupervisor.cameras(config) == [], do: [], else: [segmentation: []])
end

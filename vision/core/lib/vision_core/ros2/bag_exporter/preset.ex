defmodule VisionCore.Ros2.BagExporter.Preset do
  @moduledoc """
  What a recording of `VisionCore.Ros2.BagExporter` holds: the options of
  the `VisionCore.Ros2.ZenohExporter` that builds its messages, from the
  configuration alone, so they name what it has and no camera or pipeline
  of a vehicle, and under `:max_hz` the most values of each kind it
  records a second (`max_hz/1`).

    * **replay** — each stereo side's frames uncompressed, `mono8` on
      `<prefix>/<side>/image_raw`, with its camera info, none of the pairs'
      messages; each camera's image as it delivered it, its first JPEG
      output when it has one, else its default output encoded to JPEG,
      with its camera info; the cameras' poses on `/tf_static`. Every
      frame. What `ros2 bag play` feeds a stereo pipeline off the unit.
    * **review** — the stereo left image compressed, at most 10 a second
      when encoded from grey frames (the stereo `:raw_image_max_hz`), the
      pairs' depth and its camera info at 5 Hz; each camera's image and
      camera info as in replay, the image at 10 Hz, the camera info every
      10th image; every detection pipeline's and every segmentation
      pipeline's results; the cameras' poses. What a drive is looked at
      with, hours long.

  A part the configuration lacks, such as a stereo unit, is left out.
  """

  alias VisionCore.Camera.{Output, Unit}
  alias VisionCore.Detection.Supervisor, as: DetectionSupervisor
  alias VisionCore.Segmentation.Supervisor, as: SegmentationSupervisor
  alias VisionCore.Stereo.Supervisor, as: StereoSupervisor

  @type name :: :replay | :review

  @typedoc """
  A kind of value a preset records: the stereo pairs, the stereo sides'
  frames, the frames of the cameras of their own, the detection
  pipelines' results and the segmentation pipelines'.
  """
  @type kind :: :pairs | :sides | :cameras | :detections | :segmentation

  @names [:replay, :review]
  @kinds [:pairs, :sides, :cameras, :detections, :segmentation]
  @review_pairs_hz 5
  @review_cameras_hz 10

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
      cameras(config, [])
  end

  def options(:review, config) do
    # One camera info a second at the cameras' rate.
    cameras = cameras(config, camera_info_interval_frames: @review_cameras_hz)

    stereo(config, sides: [:left], pair_messages: [:depth]) ++
      cameras ++
      detections(config) ++
      segmentation(config) ++
      [max_hz: [pairs: @review_pairs_hz, cameras: @review_cameras_hz]]
  end

  @doc """
  The kind of value `output` hands over, `nil` for a camera's video,
  whose every frame a decoder needs.
  """
  @spec kind(VisionCore.Exporter.output()) :: kind() | nil
  def kind(:stereo_pair), do: :pairs
  def kind({:camera_frame, side}) when side in [:left, :right], do: :sides
  def kind({:camera_frame, _name}), do: :cameras
  def kind({:camera_frame, _name, _output}), do: :cameras
  def kind({:camera_video, _name, _output}), do: nil
  def kind({:detections, _name}), do: :detections
  def kind({:segmentation, _name}), do: :segmentation

  @doc """
  The most values of each kind a second that the preset `options`, as
  `options/2` gives them or a vehicle's, record, measured on capture
  times; a kind it does not name is recorded whole. `{:error, reason}`
  for a `:max_hz` that is no keyword list of kinds and positive numbers.
  """
  @spec max_hz(keyword()) :: {:ok, %{kind() => number()}} | {:error, String.t()}
  def max_hz(options) do
    case Keyword.get(options, :max_hz, []) do
      rates when is_list(rates) ->
        if Keyword.keyword?(rates) and
             Enum.all?(rates, fn {kind, hz} -> kind in @kinds and is_number(hz) and hz > 0 end),
           do: {:ok, Map.new(rates)},
           else: max_hz_error(rates)

      rates ->
        max_hz_error(rates)
    end
  end

  defp max_hz_error(rates) do
    {:error,
     "max_hz takes a keyword list of #{Enum.map_join(@kinds, ", ", &Atom.to_string/1)} " <>
       "and numbers above zero, not #{inspect(rates)}"}
  end

  defp stereo(config, options),
    do: if(StereoSupervisor.outputs(config) == [], do: [], else: [stereo: options])

  defp cameras(config, options) do
    case Unit.cameras(config) do
      [] ->
        []

      cameras ->
        jpeg_outputs =
          for {name, _driver, _server} <- cameras,
              output = jpeg_output(config, name),
              do: {name, output}

        [cameras: options ++ if(jpeg_outputs == [], do: [], else: [outputs: jpeg_outputs])]
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

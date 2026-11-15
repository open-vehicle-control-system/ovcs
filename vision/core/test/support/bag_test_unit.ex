defmodule VisionCore.BagTestUnit do
  @moduledoc """
  A vision unit with every kind of producer the bag exporter's presets
  record, for its tests: a stereo unit, a camera `:hq` with a JPEG output,
  a detection pipeline `:objects` and a segmentation pipeline `:road` on it,
  with `grey_camera: true` a camera `:usb` that sends grey frames, and
  values of each of their outputs.
  """

  alias VisionCore.Camera.Frame
  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Stereo.Pair

  @calibration Path.expand("calibration", __DIR__)

  # Names the cameras, which need not be running.
  defmodule Camera do
    @moduledoc false
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  @doc """
  The unit's configuration; with `pose:`, the camera's pose file, so that
  transforms go out, and with `grey_camera: true`, the camera `:usb`.
  """
  @spec config(keyword()) :: VisionCore.Config.t()
  def config(opts \\ []) do
    %VisionCore.Config{
      components: [
        {:stereo,
         driver: Camera,
         width: 64,
         height: 48,
         left: [
           sync: :server,
           frame_id: "stereo_left_optical",
           calibration_path: Path.join(@calibration, "stereo_left.yaml")
         ],
         right: [
           frame_id: "stereo_right_optical",
           calibration_path: Path.join(@calibration, "stereo_right.yaml")
         ]},
        {:camera,
         [
           name: :hq,
           driver: VisionCore.Camera.V4L2Single,
           frame_id: "hq_optical",
           outputs: [
             view: [resolution: {2028, 1520}, processor: :cpu, send: false],
             small: [resolution: {1014, 760}, from: :view],
             view_jpeg: [from: :view, format: :jpeg]
           ]
         ] ++ Keyword.take(opts, [:pose])},
        {:detector,
         name: :objects,
         backend: VisionCore.Detection.Backend.Stub,
         source: {:camera, :hq, :small}},
        {:segmenter,
         name: :road,
         backend: VisionCore.Segmentation.Backend.Stub,
         source: {:camera, :hq, :small}}
      ]
    }
    |> add_grey_camera(opts[:grey_camera])
  end

  defp add_grey_camera(config, true),
    do: %{config | components: config.components ++ [{:camera, name: :usb, driver: Camera}]}

  defp add_grey_camera(config, _none), do: config

  @doc "A stereo camera's frame of `side`, with grey bytes and a JPEG, captured at `capture_ns`."
  @spec stereo_frame(:left | :right, integer()) :: Frame.t()
  def stereo_frame(side, capture_ns) do
    %Frame{
      label: Atom.to_string(side),
      frame_id: "stereo_#{side}_optical",
      width: 4,
      height: 2,
      capture_ns: capture_ns,
      grey: <<0, 32, 64, 96, 128, 160, 192, 224>>,
      jpeg: <<0xFF, 0xD8, 0xFF, 0xD9>>
    }
  end

  @doc "A frame of the camera `:hq`'s JPEG output, captured at `capture_ns`."
  @spec camera_frame(integer()) :: Frame.t()
  def camera_frame(capture_ns) do
    %Frame{
      label: "hq",
      output: :view_jpeg,
      frame_id: "hq_optical",
      width: 2028,
      height: 1520,
      capture_ns: capture_ns,
      jpeg: <<0xFF, 0xD8, 0xFF, 0xD9>>
    }
  end

  @doc "A pair of the stereo unit, its left frame captured at `capture_ns`, with depth and points."
  @spec pair(integer()) :: Pair.t()
  def pair(capture_ns) do
    left = %{stereo_frame(:left, capture_ns) | width: 8, height: 4}

    %Pair{
      left_frame: left,
      right_frame: %{left | label: "right", frame_id: "stereo_right_optical"},
      left: Nx.broadcast(Nx.u8(0), {4, 8}),
      geometry: %{
        focal_length_px: 600.0,
        baseline_m: 0.08,
        left_calibration: CameraCalibration.load!(Path.join(@calibration, "stereo_left.yaml"))
      },
      disparity_range: %{min_disparity: 0, num_disparities: 2, block_size: 1},
      disparity_scale: 16,
      disparity_bytes: :binary.copy(<<0::32>>, 32),
      depth: :binary.copy(<<0::16>>, 32),
      cloud: :binary.copy(<<0::32>>, 3 * 2),
      cloud_points: 2,
      cloud_size: {1, 2}
    }
  end

  @doc "A grey frame of the camera `:usb`, captured at `capture_ns`."
  @spec grey_camera_frame(integer()) :: Frame.t()
  def grey_camera_frame(capture_ns) do
    %Frame{
      label: "usb",
      frame_id: "usb_optical",
      width: 4,
      height: 2,
      capture_ns: capture_ns,
      grey: <<0, 32, 64, 96, 128, 160, 192, 224>>
    }
  end

  @doc "The detections of `:objects` on a frame of `:hq`'s `:small` output captured at `capture_ns`."
  @spec detections(integer()) :: {Frame.t(), [map()]}
  def detections(capture_ns) do
    frame = %Frame{
      label: "hq",
      output: :small,
      frame_id: "hq_optical",
      width: 1014,
      height: 760,
      capture_ns: capture_ns
    }

    detection = %{
      label: "car",
      score: 0.8,
      x: 0.1,
      y: 0.2,
      z: 2.0,
      width: 0.5,
      height: 1.0,
      depth: 0.1,
      box: %{x0: 0.0, y0: 0.0, x1: 20.0, y1: 20.0},
      outline: [{0.0, 0.0}, {20.0, 0.0}, {20.0, 20.0}, {0.0, 20.0}],
      caption: "car 0.80 2.00m"
    }

    {frame, [detection]}
  end

  @doc "The segmentation of `:road` on a frame of `:hq` captured at `capture_ns`."
  @spec segmentation(integer()) :: {Frame.t(), map(), map()}
  def segmentation(capture_ns) do
    frame = %Frame{
      label: "hq",
      frame_id: "hq_optical",
      width: 8,
      height: 6,
      capture_ns: capture_ns
    }

    labels = %{width: 2, height: 1, data: <<0, 10>>, band: {0, 2, 8, 4}}

    clouds = %{
      road: <<1.0::float-32-little, 2.0::float-32-little, 3.0::float-32-little>>,
      off_road: <<>>,
      frame_id: "stereo_left_optical",
      capture_ns: capture_ns
    }

    {frame, labels, clouds}
  end

  @doc "A value of each output the presets read, every output captured at `capture_ns`."
  @spec values(integer()) :: [{VisionCore.Exporter.output(), VisionCore.Exporter.value()}]
  def values(capture_ns) do
    [
      {{:camera_frame, :left}, stereo_frame(:left, capture_ns)},
      {{:camera_frame, :right}, stereo_frame(:right, capture_ns)},
      {:stereo_pair, pair(capture_ns)},
      {{:camera_frame, :hq, :view_jpeg}, camera_frame(capture_ns)},
      {{:camera_frame, :usb}, grey_camera_frame(capture_ns)},
      {{:detections, :objects}, detections(capture_ns)},
      {{:segmentation, :road}, segmentation(capture_ns)}
    ]
  end
end

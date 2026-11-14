defmodule VisionCore.Segmentation.Pipeline do
  @moduledoc """
  Segments the road on a camera of its own: hands a band of every
  `:segment_every_n`-th frame of the camera to a
  `VisionCore.Segmentation.Backend`, which gives each cell of its model's
  output grid over the band a Cityscapes class, sorts the stereo points
  seen in the band into road and off-road by the class of the cell they
  land in, and publishes the result through `VisionCore.Outputs` under
  its `VisionCore.Exporter` output, `{:segmentation, name}`:

      {{:segmentation, name}, {frame, labels, clouds}}

    * `frame` — the `VisionCore.Camera.Frame` segmented, without its pixels.
    * `labels` — `%{width:, height:, data:, band: {x, y, w, h}}`: the
      model's output grid, `width * height` class ids, one byte each, row
      by row, an index into `:labels`, stretched over the band, the
      rectangle of the frame's pixels the model saw.
    * `clouds` — `%{road:, off_road:, frame_id:, capture_ns:}`: the
      points of the stereo pair matched with the frame that land in a
      road cell and in any other cell, each `x, y, z` in metres in the
      rectified left optical frame, packed little-endian 32-bit floats, in
      the order the depth map's rows give them; `frame_id` that frame's,
      the pair's (`VisionCore.Stereo.Pair.frame_id/1`), `nil` when the
      stereo unit's left camera was given none; and `capture_ns` the
      pair's capture time (`VisionCore.Stereo.Pair.capture_ns/1`), which
      the points' geometry belongs to. `nil` without a matched pair, when the
      camera's calibration or pose is missing, or when its calibration
      cannot be projected at the frame's size, such as one of another
      aspect ratio (`VisionCore.CameraDepth.lens/2`).

  ## The band

  The model's input is 2:1, so the band is the frame's full width and
  half that in rows (`band/3`), its top at `:band_top`, a fraction of the
  frame's height, kept inside the frame: at 1, the default, it touches
  the frame's bottom, where the road is. A frame wider than 2:1 is all
  band.
  The backend is sent the band's rows only, and stretches them onto the
  model's input; pixels outside the band have no class.

  ## A point's cell

  A projected point's `(u, v)` follows OpenCV's convention, pixel `i`
  centred on `i`, and the Port's resize samples the band at its pixels'
  centres, so a `W × H` grid's cell `c` covers `u` from `x + c · w / W − ½`
  to `x + (c + 1) · w / W − ½` of the band `{x, y, w, h}`. A point is in
  the cell `(⌊(u − x + ½) · W / w⌋, ⌊(v − y + ½) · H / h⌋)`, and in
  neither cloud when that is outside the grid.

  ## The stereo pair

  The frame is matched with the stereo pair captured closest to it
  (`VisionCore.CameraDepth`, as a detection pipeline on a
  camera does), once its label image is back: the label images wait for
  their pairs in a queue (`VisionCore.CameraDepth.Queue`) while the
  next frames go to the backend, and are published in capture order; each
  waits at most `:pair_wait_ms`, and not at all while the stereo pairs
  have stalled, two pair periods without one. While 32 label images wait,
  the camera's frames are skipped.

  The pair's depth is projected into the frame through the camera's
  calibration and pose
  (`VisionCore.CameraDepth.Reprojection.project_with_origin/4`, every
  `:reprojection_stride`-th pixel and row). A camera without a
  calibration or a pose, or whose calibration cannot be projected at the
  frame's size, publishes its label images without clouds, without
  waiting for a pair.

  The calibration and the pose are read at start, and again when a
  calibration of the camera is committed (`VisionCore.CameraPipeline`):
  the clouds are sorted with it from the next frame on, as the ROS 2
  exporter's label `camera_info` follows it.

  ## One band in flight

  `VisionCore.CameraPipeline` runs the pipeline: it segments every
  `:segment_every_n`-th frame, one band in flight at a time, the newest
  frame held meanwhile, and publishes the label images in capture
  order. The model needs colour: a frame to segment without RGB pixels
  is skipped, which is logged once.

  ## Options

    * `:name` (required) — the pipeline's name: it registers as
      `VisionCore.Pipelines.server(VisionCore.Segmentation.Pipeline, name)`
      and declares its parameter groups as `<name>.*`.
    * `:source` (required) — `{:camera, name}`, the camera of its own
      `name` (`VisionCore.Camera.Unit`), or `{:camera, name, output}`,
      that camera's output `output` (`VisionCore.Camera.Output`).
    * `:backend` (`VisionCore.Segmentation.Backend.Qnn`) and
      `:backend_server` (the `:backend` module).
    * `:band_top` (`1.0`, the band touching the frame's bottom) — the
      band's top as a fraction of the frame's height, from 0 to 1.
    * `:labels` (the 19 Cityscapes classes, `VisionCore.Segmentation.labels/0`)
      — class id to name.
    * `:road_classes` (`["road"]`) — the names of the classes that are
      road; each one of `:labels`.
    * `:segment_every_n` (`1`) — segment every nth frame (see "One band
      in flight").
    * `:reprojection_stride` (`3`) — every nth pixel and row of the depth
      map projected into the camera's image.
    * `:pair_wait_ms` (`500`) — the longest a label image waits for the
      pair captured closest to its frame, and how far before the newest
      pair's capture the pairs are kept.
    * `:config` (the active `VisionCore.Config`) — the configuration the
      camera is read from.
    * `:clock` (`System.monotonic_time/1` in nanoseconds) — the time the
      waits for a pair are measured with, a function of no argument.

  ## Settings

  `:segment_every_n`, `:band_top`, `:reprojection_stride` and
  `:pair_wait_ms` are the pipeline's settings (`setting_specs/0`, with
  the values each takes): a composer's value outside them fails the
  start, and each is a live vision parameter (`groups/1`), which changes
  while the pipeline runs, from the next frame on (`put_setting/3`). A
  new `:pair_wait_ms` applies to the label images that come back from
  then on.
  """
  @behaviour VisionCore.CameraPipeline

  require Logger

  alias VisionCore.Camera.Frame
  alias VisionCore.Pipelines
  alias VisionCore.CameraDepth
  alias VisionCore.CameraDepth.Reprojection
  alias VisionCore.{CameraPipeline, Settings}
  alias VisionCore.Stereo.Pair

  @default_backend VisionCore.Segmentation.Backend.Qnn
  @setting_specs [
    segment_every_n: %{
      type: :integer,
      range: {1, 1000},
      default: 1,
      description: "Images per segmentation; 1 segments every image"
    },
    band_top: %{
      type: :double,
      range: {0, 1},
      default: 1.0,
      description:
        "Top of the band the model sees, as a share of the image's height; " <>
          "1 puts the band at the image's bottom"
    },
    reprojection_stride: %{
      type: :integer,
      range: {1, 32},
      default: 3,
      description: "Every how many pixels and rows of the depth are projected"
    },
    pair_wait_ms: %{
      type: :integer,
      range: {0, 60_000},
      default: 500,
      description: "Longest wait for the matching pair, in ms"
    }
  ]

  @wording %{
    calibration: "its segmentation has no clouds",
    pose: "its segmentation has no clouds",
    unreadable: "its segmentation has no clouds",
    unmatched: "its segmentation has no clouds",
    lens: "project the stereo points"
  }

  @doc false
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts) do
    registration =
      case Keyword.get(opts, :name) do
        nil -> []
        name -> [name: Pipelines.server(__MODULE__, name)]
      end

    CameraPipeline.start_link(__MODULE__, opts, registration)
  end

  @doc """
  The band of a `width × height` frame the model sees, `{x, y, w, h}` in
  the frame's pixels: full width, `round(width / 2)` rows, or the whole
  frame when it has fewer, its top at `band_top`, a fraction of the
  height, moved up to keep the band inside the frame: 1 puts it at the
  frame's bottom.
  """
  @spec band(pos_integer(), pos_integer(), number()) ::
          {0, non_neg_integer(), pos_integer(), pos_integer()}
  def band(width, height, band_top) do
    band_height = min(round(width / 2), height)
    lowest = height - band_height
    {0, min(round(band_top * height), lowest), width, band_height}
  end

  @impl CameraPipeline
  def init(opts) do
    backend = Keyword.get(opts, :backend, @default_backend)
    labels = Keyword.get(opts, :labels, VisionCore.Segmentation.labels())
    road_classes = Keyword.get(opts, :road_classes, VisionCore.Segmentation.road_classes())

    Map.merge(Settings.init!(@setting_specs, opts), %{
      name: VisionCore.Segmentation.name!(opts),
      source: source!(Keyword.get(opts, :source)),
      backend: backend,
      backend_server: Keyword.get(opts, :backend_server, backend),
      labels: labels,
      road_classes: road_classes,
      road: road!(road_classes, labels),
      colourless_logged: false
    })
  end

  @doc "The pipeline's settings: each with its type, the values it takes and its default."
  @spec setting_specs() :: Settings.specs()
  def setting_specs, do: @setting_specs

  @doc """
  Changes the setting `key` of the pipeline `name` to `value`, from the
  next frame on, or says why its spec refuses it.
  """
  @spec put_setting(atom(), atom(), term()) :: :ok | {:error, String.t()}
  def put_setting(name, key, value),
    do: GenServer.call(Pipelines.server(__MODULE__, name), {:put_setting, key, value})

  @doc "The settings of the pipeline `name` as it runs, by their names."
  @spec live_settings(atom()) :: %{String.t() => term()}
  def live_settings(name), do: GenServer.call(Pipelines.server(__MODULE__, name), :live_settings)

  @impl CameraPipeline
  def with_setting(settings, key, value), do: Settings.put(@setting_specs, settings, key, value)

  @impl CameraPipeline
  def setting_values(settings), do: Settings.values(@setting_specs, settings)

  # A camera source names its output, `nil` for the camera's default.
  defp source!({:camera, camera}), do: source!({:camera, camera, nil})

  defp source!({:camera, camera, output} = source) when is_atom(camera) and is_atom(output),
    do: source

  defp source!(source),
    do:
      raise(
        ArgumentError,
        "its :source is {:camera, name}, a camera of its own, or {:camera, name, output}, " <>
          "one of its outputs, got #{inspect(source)}"
      )

  @impl CameraPipeline
  def every_n(settings), do: settings.segment_every_n

  @impl CameraPipeline
  def depth_wording(settings), do: {"segmentation pipeline #{settings.name}", @wording}

  @impl CameraPipeline
  def output_key(settings), do: VisionCore.Segmentation.output(settings.name)

  # Whether each class id, 0 to 255, is road.
  defp road!(road_classes, labels) do
    road_ids =
      for class <- road_classes do
        Enum.find_index(labels, &(&1 == class)) ||
          raise ArgumentError,
                "its :road_classes name #{inspect(class)}, which is none of its :labels"
      end

    List.to_tuple(for id <- 0..255, do: id in road_ids)
  end

  @doc """
  The segmentation pipeline's steps around the inference, for what it
  keeps of its options: `<name>.input` and `<name>.classes` in the
  pipeline `name`, with its settings, live, their defaults the values it
  starts with; `road_classes` is fixed at start. They are read from the
  calling process and set on it, as `live_settings/1` and `put_setting/3`
  do by name: the pipeline calls this itself, once it runs, so a
  pipeline started again under the same name is never called for the
  groups of the one before. The backend declares the inference step
  itself (`VisionCore.Segmentation.inference_group/2`).
  """
  @impl CameraPipeline
  def groups(%{name: name, source: {:camera, camera, _output}} = settings) do
    pipeline = self()
    set = fn key, value -> GenServer.call(pipeline, {:put_setting, key, value}) end

    live = fn keys ->
      %{
        compute: VisionCore.Parameters.on_the_beam(),
        values: fn -> GenServer.call(pipeline, :live_settings) end,
        parameters: Settings.parameters(@setting_specs, keys, settings, set)
      }
    end

    [
      VisionCore.Parameters.step(
        name,
        "input",
        "Input",
        101,
        Map.merge(live.([:segment_every_n, :band_top]), %{
          summary: "Hands a band of every nth image of the camera #{camera} to the model.",
          explanation:
            "Takes the images of the camera #{camera} and hands the model a band of each, its " <>
              "full width and half that in height, the model's shape. band_top is where the " <>
              "band's top is, as a share of the image's height; at 1 the band touches the " <>
              "image's bottom, where the road is. The rest of the image gets no class. " <>
              "segment_every_n segments one image out of n: a higher value leaves the NPU " <>
              "more time and updates the classes less often. An image to segment that " <>
              "arrives while the model is still busy waits, the newest one only, and goes " <>
              "to the model as soon as it is done."
        })
      ),
      VisionCore.Parameters.step(
        name,
        "classes",
        "Classes",
        103,
        classes_step(live.([:reprojection_stride, :pair_wait_ms]), settings)
      )
    ]
  end

  defp classes_step(live, settings) do
    road_classes =
      VisionCore.Stereo.Parameters.build_parameter(
        {:road_classes, Enum.join(settings.road_classes, ", ")},
        "Classes that are road"
      )

    Map.merge(live, %{
      summary: "Sorts the stereo points seen in the band into road and off-road.",
      explanation:
        "Projects the depth of the stereo pair captured closest to the image into the " <>
          "camera's image, through its calibration and its pose relative to the stereo " <>
          "pair, and sorts each point by the class of the part of the band it lands in: " <>
          "road for the classes in road_classes, fixed in the build, off-road for every " <>
          "other. Points outside the band are left out. reprojection_stride is every how " <>
          "many pixels and rows of the depth it projects, a higher value sorting faster " <>
          "and fewer points; pair_wait_ms, how long the classes wait for that pair. The " <>
          "next images go to the model meanwhile, and the classes are published in the " <>
          "images' order. While the stereo pairs have stopped, the classes are published " <>
          "at once, with the pair already kept if one was captured within half a pair " <>
          "period of the image. Without such a pair, or without the camera's calibration " <>
          "or pose, they are published without points.",
      parameters: [road_classes | live.parameters]
    })
  end

  @impl CameraPipeline
  def accept(%Frame{rgb: rgb}, settings) when is_binary(rgb), do: {:ok, settings}
  def accept(_colourless, settings), do: {:skip, note_colourless(settings)}

  defp note_colourless(%{colourless_logged: true} = settings), do: settings

  defp note_colourless(%{source: {:camera, camera, _output}} = settings) do
    Logger.warning(
      "segmentation pipeline #{settings.name}: camera #{camera}'s images have no " <>
        "colour, which its model needs, so none is segmented"
    )

    %{settings | colourless_logged: true}
  end

  @impl CameraPipeline
  def prepare(frame, settings) do
    {_x, top, width, height} = band = band(frame.width, frame.height, settings.band_top)
    rgb = binary_part(frame.rgb, top * width * 3, height * width * 3)
    {:submit, %{width: width, height: height, rgb: rgb}, band, settings}
  end

  @impl CameraPipeline
  def submit(band, sequence, settings),
    do: settings.backend.segment(settings.backend_server, sequence, band)

  @impl CameraPipeline
  def reply_tag, do: :inference_labels

  @impl CameraPipeline
  def stage(:prepare), do: :input
  def stage(:result), do: nil
  def stage(:finish), do: :classes

  @doc """
  The time of each of the pipeline's steps, `:input`, `:inference` and
  `:classes`, over the frames segmented since the last call
  (`VisionCore.CameraPipeline.stage_times/1`).
  """
  @spec stage_times(GenServer.server()) :: VisionCore.StageTimes.t()
  defdelegate stage_times(server), to: CameraPipeline

  @impl CameraPipeline
  def result(labels, band, _settings), do: {Map.put(labels, :band, band), true}

  @impl CameraPipeline
  def finish(frame, labels, nil, camera, settings),
    do: {message(settings, frame, labels, nil), camera}

  def finish(frame, labels, pair, camera, settings) do
    {clouds, camera} = clouds(frame, labels, pair, camera, settings)
    {message(settings, frame, labels, clouds), camera}
  end

  defp message(settings, frame, labels, clouds),
    do: {VisionCore.Segmentation.output(settings.name), {frame, labels, clouds}}

  defp clouds(frame, labels, pair, camera, settings) do
    {lens, camera} = CameraDepth.lens(camera, {frame.width, frame.height})

    if lens do
      %{points: points} =
        Reprojection.project_with_origin(pair, lens, camera.pose, settings.reprojection_stride)

      {road, off_road} = sort_points(points, labels, settings.road, <<>>, <<>>)

      clouds = %{
        road: road,
        off_road: off_road,
        frame_id: Pair.frame_id(pair),
        capture_ns: Pair.capture_ns(pair)
      }

      {clouds, camera}
    else
      {nil, camera}
    end
  end

  defp sort_points(
         <<u::float-32-native, v::float-32-native, x::float-32-native, y::float-32-native,
           z::float-32-native, rest::binary>>,
         labels,
         road,
         road_points,
         off_road_points
       ) do
    case cell_class(u, v, labels) do
      nil ->
        sort_points(rest, labels, road, road_points, off_road_points)

      class ->
        point = <<x::float-32-little, y::float-32-little, z::float-32-little>>

        if elem(road, class),
          do:
            sort_points(
              rest,
              labels,
              road,
              <<road_points::binary, point::binary>>,
              off_road_points
            ),
          else:
            sort_points(
              rest,
              labels,
              road,
              road_points,
              <<off_road_points::binary, point::binary>>
            )
    end
  end

  defp sort_points(<<>>, _labels, _road, road_points, off_road_points),
    do: {road_points, off_road_points}

  # The class of the cell the point `(u, v)` of the frame is in, `nil` outside the grid.
  defp cell_class(u, v, %{width: cells_x, height: cells_y, data: data, band: band}) do
    {x, y, width, height} = band
    cell_x = floor((u - x + 0.5) * cells_x / width)
    cell_y = floor((v - y + 0.5) * cells_y / height)

    if cell_x >= 0 and cell_x < cells_x and cell_y >= 0 and cell_y < cells_y,
      do: :binary.at(data, cell_y * cells_x + cell_x)
  end
end

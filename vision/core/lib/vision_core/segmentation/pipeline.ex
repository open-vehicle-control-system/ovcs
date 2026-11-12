defmodule VisionCore.Segmentation.Pipeline do
  @moduledoc """
  Segments the road on a camera of its own: hands a band of every
  `:segment_every_n`-th frame of the camera to a
  `VisionCore.Segmentation.Backend`, which gives each cell of its model's
  output grid over the band a Cityscapes class, sorts the stereo points
  seen in the band into road and off-road by the class of the cell they
  land in, and publishes the result through `VisionCore.Outputs` under
  `{:segmentation, server}`, `server` being the name it is registered
  under (`VisionCore.Detection.server/2`):

      {:segmentation, name, frame, labels, clouds}

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
      aspect ratio (`VisionCore.Detection.CameraDepth.lens/2`).

  ## The band

  The model's input is 2:1, so the band is the frame's full width and
  half that in rows (`band/3`), its top at `:band_top`, a fraction of the
  frame's height, kept inside the frame; by default it touches the
  frame's bottom, where the road is. A frame wider than 2:1 is all band.
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
  (`VisionCore.Detection.CameraDepth`, as a detection pipeline on a
  camera does), once its label image is back: the label images wait for
  their pairs in a queue (`VisionCore.Detection.DepthQueue`) while the
  next frames go to the backend, and are published in capture order; each
  waits at most `:pair_wait_ms`, and not at all while the stereo pairs
  have stalled, two pair periods without one. While 32 label images wait,
  the camera's frames are skipped.

  The pair's depth is projected into the frame through the camera's
  calibration and pose
  (`VisionCore.Detection.Reprojection.project_with_origin/4`, every
  `:reprojection_stride`-th pixel and row). A camera without a
  calibration or a pose, or whose calibration cannot be projected at the
  frame's size, publishes its label images without clouds, without
  waiting for a pair.

  The calibration and the pose are read at start. A calibration
  committed through the camera's `set_camera_info` reaches the ROS 2
  exporter's label `camera_info` at once, but the clouds are sorted
  with the start-time calibration until the unit restarts.

  ## One band in flight

  `:segment_every_n` counts the camera's frames that come while fewer
  than 32 label images wait, a frame that comes while a band is in
  flight included: the `n`th, `2n`th, `3n`th… of them are to be
  segmented, with `n` = 2 the second, fourth, sixth… The model needs
  colour: of those, a frame without RGB pixels is skipped, which is
  logged once.

  One band is in flight at a time, submitted under a sequence number its
  reply is matched on. A frame to be segmented that comes meanwhile is
  held, in place of the one held before, and submitted once that reply
  is handled, `nil` included, before the reply's label image is matched
  with a pair. It is not submitted as soon as the backend is free: the reply
  may still be waiting to be read, and would be lost. The frame held is
  dropped when 32 label images wait once the reply is handled, or when
  the backend refuses it.

  ## Options

    * `:name` (required) — the pipeline's name: it registers as
      `VisionCore.Detection.server(VisionCore.Segmentation.Pipeline, name)`
      and declares its parameter groups as `<name>.*`.
    * `:source` (required) — `{:camera, name}`, the camera of its own
      `name` (`VisionCore.Camera.Unit`), or `{:camera, name, output}`,
      that camera's output `output` (`VisionCore.Camera.Output`).
    * `:backend` (`VisionCore.Segmentation.Backend.Qnn`) and
      `:backend_server` (the `:backend` module).
    * `:band_top` (the band touching the frame's bottom) — the band's top
      as a fraction of the frame's height, from 0 to 1.
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
  """
  use GenServer

  require Logger

  alias VisionCore.Camera.Frame
  alias VisionCore.Detection
  alias VisionCore.Detection.{CameraDepth, DepthQueue, Reprojection}
  alias VisionCore.{Options, Outputs}
  alias VisionCore.Stereo.Pair

  @default_backend VisionCore.Segmentation.Backend.Qnn
  @default_segment_every_n 1
  @default_reprojection_stride 3
  @default_pair_wait_ms 500

  @wording %{
    calibration: "its segmentation has no clouds",
    pose: "its segmentation has no clouds",
    unreadable: "its segmentation has no clouds",
    unmatched: "its segmentation has no clouds",
    lens: "project the stereo points"
  }

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name && Detection.server(__MODULE__, name))
  end

  @doc """
  The band of a `width × height` frame the model sees, `{x, y, w, h}` in
  the frame's pixels: full width, `round(width / 2)` rows, or the whole
  frame when it has fewer, its top at `band_top`, a fraction of the
  height, moved up to keep the band inside the frame; `nil` puts it at
  the frame's bottom.
  """
  @spec band(pos_integer(), pos_integer(), number() | nil) ::
          {0, non_neg_integer(), pos_integer(), pos_integer()}
  def band(width, height, band_top) do
    band_height = min(round(width / 2), height)
    lowest = height - band_height
    top = if is_nil(band_top), do: lowest, else: min(round(band_top * height), lowest)
    {0, top, width, band_height}
  end

  @impl GenServer
  def init(opts) do
    name = VisionCore.Segmentation.name!(opts)
    backend = Keyword.get(opts, :backend, @default_backend)
    labels = Keyword.get(opts, :labels, VisionCore.Segmentation.labels())
    road_classes = Keyword.get(opts, :road_classes, VisionCore.Segmentation.road_classes())
    pair_wait_ms = Options.integer!(opts, :pair_wait_ms, @default_pair_wait_ms, 0)

    state = %{
      name: name,
      camera: camera_depth(Keyword.get(opts, :source), name, pair_wait_ms, opts),
      backend: backend,
      backend_server: Keyword.get(opts, :backend_server, backend),
      band_top: band_top!(Keyword.get(opts, :band_top)),
      labels: labels,
      road_classes: road_classes,
      road: road!(road_classes, labels),
      segment_every_n: Options.integer!(opts, :segment_every_n, @default_segment_every_n, 1),
      reprojection_stride:
        Options.integer!(opts, :reprojection_stride, @default_reprojection_stride, 1),
      pair_wait_ms: pair_wait_ms,
      # The sequence of the last submission, accepted or not.
      sequence: 0,
      frame_count: 0,
      # The in-flight inference's sequence, and the frame submitted with it, with its band.
      pending: nil,
      # The newest frame to segment that came while a band was in flight, with its pixels.
      held: nil,
      # Frames' label images waiting for the pair captured closest to each.
      waiting: DepthQueue.new(pair_wait_ms),
      clock: Keyword.get(opts, :clock, &monotonic_ns/0),
      colourless_logged: false
    }

    if Process.whereis(VisionCore.Parameters),
      do: :ok = VisionCore.Parameters.declare(groups(state))

    :ok = Outputs.subscribe({:stereo_pair, VisionCore.Stereo.Pipeline})
    :ok = Outputs.subscribe(state.camera.key)
    {:ok, state}
  end

  defp monotonic_ns, do: System.monotonic_time(:nanosecond)

  defp camera_depth({:camera, camera}, name, pair_wait_ms, opts),
    do: camera_depth({:camera, camera, nil}, name, pair_wait_ms, opts)

  defp camera_depth({:camera, camera, output}, name, pair_wait_ms, opts)
       when is_atom(camera) and is_atom(output) do
    config =
      Keyword.get_lazy(opts, :config, &VisionCore.Application.active_config/0) ||
        %VisionCore.Config{}

    CameraDepth.new(camera, config, "segmentation pipeline #{name}", @wording,
      pair_wait_ms: pair_wait_ms,
      output: output
    )
  end

  defp camera_depth(source, _name, _pair_wait_ms, _opts),
    do:
      raise(
        ArgumentError,
        "its :source is {:camera, name}, a camera of its own, or {:camera, name, output}, " <>
          "one of its outputs, got #{inspect(source)}"
      )

  defp band_top!(band_top)
       when is_nil(band_top) or (is_number(band_top) and band_top >= 0 and band_top <= 1),
       do: band_top

  defp band_top!(band_top),
    do:
      raise(
        ArgumentError,
        "its :band_top is a fraction of the frame's height, from 0 to 1, got #{inspect(band_top)}"
      )

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
  The segmentation pipeline's steps around the inference, for a running
  `state`: `<name>.input` and `<name>.classes` in the pipeline `name`,
  with their settings fixed at start. The backend declares the inference
  step itself (`VisionCore.Segmentation.inference_group/2`).
  """
  @spec groups(map()) :: [VisionCore.Parameters.group_declaration()]
  def groups(state) do
    camera = state.camera.name

    [
      VisionCore.Parameters.step(state.name, "input", "Input", 101, %{
        summary: "Hands a band of every nth image of the camera #{camera} to the model.",
        explanation:
          "Takes the images of the camera #{camera} and hands the model a band of each, its " <>
            "full width and half that in height, the model's shape. band_top, fixed in the " <>
            "build, is where the band's top is, as a share of the image's height; by default " <>
            "the band touches the image's bottom, where the road is. The rest of the image " <>
            "gets no class. segment_every_n, fixed in the build, segments one image out of n: " <>
            "a higher value leaves the NPU more time and updates the classes less often. An " <>
            "image to segment that arrives while the model is still busy waits, the newest " <>
            "one only, and goes to the model as soon as it is done.",
        compute: VisionCore.Parameters.on_the_beam(),
        parameters: [
          build_parameter(:segment_every_n, state.segment_every_n, "Images per segmentation"),
          build_parameter(
            :band_top,
            state.band_top || "bottom",
            "Top of the band the model sees, as a share of the image's height"
          )
        ]
      }),
      VisionCore.Parameters.step(state.name, "classes", "Classes", 103, %{
        summary: "Sorts the stereo points seen in the band into road and off-road.",
        explanation:
          "Projects the depth of the stereo pair captured closest to the image into the " <>
            "camera's image, through its calibration and its pose relative to the stereo " <>
            "pair, and sorts each point by the class of the part of the band it lands in: " <>
            "road for the classes in road_classes, off-road for every other. Points outside " <>
            "the band are left out. Fixed in the build: road_classes; reprojection_stride, " <>
            "every how many pixels and rows of the depth it projects, a higher value sorting " <>
            "faster and fewer points; and pair_wait_ms, how long the classes wait for that " <>
            "pair. The next images go to the model meanwhile, and the classes are published " <>
            "in the images' order. While the stereo pairs have stopped, the classes are " <>
            "published at once, with the pair already kept if one was captured within half " <>
            "a pair period of the image. Without such a pair, or without the camera's " <>
            "calibration or pose, they are published without points.",
        compute: VisionCore.Parameters.on_the_beam(),
        parameters: [
          build_parameter(
            :road_classes,
            Enum.join(state.road_classes, ", "),
            "Classes that are road"
          ),
          build_parameter(
            :reprojection_stride,
            state.reprojection_stride,
            "Every how many pixels and rows of the depth are projected"
          ),
          build_parameter(
            :pair_wait_ms,
            state.pair_wait_ms,
            "Longest wait for the matching pair, in ms"
          )
        ]
      })
    ]
  end

  defp build_parameter(key, value, description),
    do: VisionCore.Stereo.Parameters.build_parameter({key, value}, description)

  @impl GenServer
  def handle_cast({:stereo_pair, %Pair{} = pair}, state) do
    now_ns = state.clock.()
    state = %{state | camera: CameraDepth.add_pair(state.camera, pair, now_ns)}
    {:noreply, publish_settled(state, now_ns)}
  end

  def handle_cast({:camera_frame, %Frame{} = frame}, state) do
    case DepthQueue.admit(state.waiting, state.camera) do
      {:ok, waiting} -> {:noreply, take_frame(frame, %{state | waiting: waiting})}
      {:full, waiting} -> {:noreply, %{state | waiting: waiting}}
    end
  end

  def handle_cast(_message, state), do: {:noreply, state}

  defp take_frame(frame, state) do
    frame_count = state.frame_count + 1
    state = %{state | frame_count: frame_count}

    cond do
      rem(frame_count, state.segment_every_n) != 0 -> state
      not is_binary(frame.rgb) -> note_colourless(state)
      not is_nil(state.pending) -> %{state | held: frame}
      true -> submit(frame, state)
    end
  end

  # Submits the frame held while the queue has room for its label image.
  defp submit_held(%{held: nil} = state), do: state

  defp submit_held(%{held: frame} = state) do
    case DepthQueue.admit(state.waiting, state.camera) do
      {:ok, waiting} -> submit(frame, %{state | held: nil, waiting: waiting})
      {:full, waiting} -> %{state | held: nil, waiting: waiting}
    end
  end

  defp submit(frame, state) do
    {_x, top, width, height} = band = band(frame.width, frame.height, state.band_top)
    rgb = binary_part(frame.rgb, top * width * 3, height * width * 3)
    sequence = state.sequence + 1
    state = %{state | sequence: sequence}

    case state.backend.segment(state.backend_server, sequence, %{
           width: width,
           height: height,
           rgb: rgb
         }) do
      :ok ->
        %{state | pending: %{sequence: sequence, frame: %{frame | rgb: nil}, band: band}}

      # Busy or unavailable: the backend logs the unavailable case once.
      {:error, _reason} ->
        state
    end
  end

  defp note_colourless(%{colourless_logged: true} = state), do: state

  defp note_colourless(state) do
    Logger.warning(
      "segmentation pipeline #{state.name}: camera #{state.camera.name}'s images have no " <>
        "colour, which its model needs, so none is segmented"
    )

    %{state | colourless_logged: true}
  end

  @impl GenServer
  def handle_info(
        {:inference_labels, sequence, labels},
        %{pending: %{sequence: sequence, frame: frame, band: band}} = state
      ) do
    state = %{state | pending: nil}

    if is_nil(labels),
      do: {:noreply, submit_held(state)},
      else: {:noreply, wait_for_pair(state, frame, Map.put(labels, :band, band))}
  end

  # A reply for a frame no longer waited on.
  def handle_info({:inference_labels, _stale, _labels}, state), do: {:noreply, state}

  def handle_info(:pair_wait, state),
    do: {:noreply, publish_settled(state, state.clock.())}

  def handle_info(_message, state), do: {:noreply, state}

  defp wait_for_pair(state, frame, labels) do
    now_ns = state.clock.()
    {lens, camera} = CameraDepth.lens(state.camera, {frame.width, frame.height})

    waiting =
      if lens && CameraDepth.projectable?(camera),
        do: DepthQueue.put(state.waiting, {frame, labels}, frame.capture_ns, now_ns),
        else: DepthQueue.put_without_depth(state.waiting, {frame, labels})

    # Submitted first, so the backend runs while the clouds are sorted.
    %{state | camera: camera, waiting: waiting}
    |> submit_held()
    |> publish_settled(now_ns)
  end

  # Publishes the label images whose pair is known, in capture order, and has the pipeline told when to look again.
  defp publish_settled(state, now_ns) do
    state = %{state | camera: CameraDepth.add_queued_pairs(state.camera, now_ns)}
    {settled, waiting} = DepthQueue.settle(state.waiting, state.camera, now_ns)
    state = %{state | waiting: DepthQueue.schedule(waiting, state.camera, now_ns)}

    Enum.reduce(settled, state, fn {labelled, pair}, state ->
      publish_labels(labelled, pair, state)
    end)
  end

  defp publish_labels({frame, labels}, nil, state) do
    publish(state, frame, labels, nil)
    state
  end

  defp publish_labels({frame, labels}, pair, state) do
    {clouds, state} = clouds(frame, labels, pair, state)
    publish(state, frame, labels, clouds)
    state
  end

  defp clouds(frame, labels, pair, state) do
    {lens, camera} = CameraDepth.lens(state.camera, {frame.width, frame.height})
    state = %{state | camera: camera}

    if lens do
      %{points: points} =
        Reprojection.project_with_origin(pair, lens, camera.pose, state.reprojection_stride)

      {road, off_road} = sort_points(points, labels, state.road, <<>>, <<>>)

      clouds = %{
        road: road,
        off_road: off_road,
        frame_id: Pair.frame_id(pair),
        capture_ns: Pair.capture_ns(pair)
      }

      {clouds, state}
    else
      {nil, state}
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

  defp publish(state, frame, labels, clouds),
    do:
      Outputs.publish(
        {:segmentation, Detection.server(__MODULE__, state.name)},
        {:segmentation, state.name, frame, labels, clouds}
      )
end

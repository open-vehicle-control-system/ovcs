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
    * `clouds` — `%{road:, off_road:, frame_id:}`: the points of the
      stereo pair matched with the frame that land in a road cell and in
      any other cell, each `x, y, z` in metres in the rectified left
      optical frame, packed little-endian 32-bit floats, in the order the
      depth map's rows give them, and `frame_id` that frame's, the pair's
      (`VisionCore.Stereo.Pair.frame_id/1`). `nil` without a matched pair,
      or when the camera's calibration or pose is missing.

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
  camera does), once its label image is back: the label image waits for
  that pair at most `:pair_wait_ms`, and the camera's frames that come
  meanwhile are skipped. The pair's depth is projected into the frame
  through the camera's calibration and pose
  (`VisionCore.Detection.Reprojection.project_with_origin/4`, every
  `:reprojection_stride`-th pixel and row). A camera without a
  calibration or a pose publishes its label images at once, without
  clouds.

  The model needs colour: a frame without RGB pixels is skipped, which
  is logged once.

  ## Options

    * `:name` (required) — the pipeline's name: it registers as
      `VisionCore.Detection.server(VisionCore.Segmentation.Pipeline, name)`
      and declares its parameter groups as `<name>.*`.
    * `:source` (required) — `{:camera, name}`, the camera of its own
      `name` (`VisionCore.Camera.Unit`).
    * `:backend` (`VisionCore.Segmentation.Backend.Qnn`) and
      `:backend_server` (the `:backend` module).
    * `:band_top` (the band touching the frame's bottom) — the band's top
      as a fraction of the frame's height, from 0 to 1.
    * `:labels` (the 19 Cityscapes classes, `VisionCore.Segmentation.labels/0`)
      — class id to name.
    * `:road_classes` (`["road"]`) — the names of the classes that are
      road; each one of `:labels`.
    * `:segment_every_n` (`1`) — segment every nth frame.
    * `:reprojection_stride` (`3`) — every nth pixel and row of the depth
      map projected into the camera's image.
    * `:pair_wait_ms` (`500`) — the longest a label image waits for the
      pair captured closest to its frame.
    * `:config` (the active `VisionCore.Config`) — the configuration the
      camera is read from.
  """
  use GenServer

  require Logger

  alias VisionCore.Camera.Frame
  alias VisionCore.Detection
  alias VisionCore.Detection.{CameraDepth, Reprojection}
  alias VisionCore.Outputs
  alias VisionCore.Stereo.Pair

  @default_backend VisionCore.Segmentation.Backend.Qnn
  @default_road_classes ["road"]
  @default_segment_every_n 1
  @default_reprojection_stride 3
  @default_pair_wait_ms 500

  @wording %{
    calibration: "its segmentation has no clouds",
    pose: "its segmentation has no clouds",
    unreadable: "its segmentation has no clouds",
    lens: "project the stereo points"
  }

  @on_the_beam %{runs_on: :cpu, implementation: :elixir, backend: nil}

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
    road_classes = Keyword.get(opts, :road_classes, @default_road_classes)

    state = %{
      name: name,
      camera: camera_depth(Keyword.get(opts, :source), name, opts),
      backend: backend,
      backend_server: Keyword.get(opts, :backend_server, backend),
      band_top: band_top!(Keyword.get(opts, :band_top)),
      labels: labels,
      road_classes: road_classes,
      road: road!(road_classes, labels),
      segment_every_n: integer!(opts, :segment_every_n, @default_segment_every_n, 1),
      reprojection_stride: integer!(opts, :reprojection_stride, @default_reprojection_stride, 1),
      pair_wait_ms: integer!(opts, :pair_wait_ms, @default_pair_wait_ms, 0),
      sequence: 0,
      frame_count: 0,
      # The frame submitted with the in-flight inference, with its band.
      pending: nil,
      # A frame's label image waiting for the pair captured closest to it.
      awaiting: nil,
      unmatched_logged: false,
      colourless_logged: false
    }

    if Process.whereis(VisionCore.Parameters),
      do: :ok = VisionCore.Parameters.declare(groups(state))

    :ok = Outputs.subscribe({:stereo_pair, VisionCore.Stereo.Pipeline})
    :ok = Outputs.subscribe({:camera_frame, state.camera.server})
    {:ok, state}
  end

  defp camera_depth({:camera, camera}, name, opts) when is_atom(camera) do
    config =
      Keyword.get_lazy(opts, :config, &VisionCore.Application.active_config/0) ||
        %VisionCore.Config{}

    CameraDepth.new(camera, config, "segmentation pipeline #{name}", @wording)
  end

  defp camera_depth(source, _name, _opts),
    do:
      raise(
        ArgumentError,
        "its :source is {:camera, name}, a camera of its own, got #{inspect(source)}"
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

  # `opts`' `key`, an integer from `least` on.
  defp integer!(opts, key, default, least) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= least ->
        value

      value ->
        raise ArgumentError,
              "its #{inspect(key)} is an integer from #{least} on, got #{inspect(value)}"
    end
  end

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
      VisionCore.Segmentation.step(state.name, "input", "Input", 101, %{
        summary: "Hands a band of every nth image of the camera #{camera} to the model.",
        explanation:
          "Takes the images of the camera #{camera} and hands the model a band of each, its " <>
            "full width and half that in height, the model's shape. band_top, fixed in the " <>
            "build, is where the band's top is, as a share of the image's height; by default " <>
            "the band touches the image's bottom, where the road is. The rest of the image " <>
            "gets no class. segment_every_n, fixed in the build, segments one image out of n: " <>
            "a higher value leaves the NPU more time and updates the classes less often. An " <>
            "image that arrives while the model is still busy is skipped.",
        compute: @on_the_beam,
        parameters: [
          build_parameter(:segment_every_n, state.segment_every_n, "Images per segmentation"),
          build_parameter(
            :band_top,
            state.band_top || "bottom",
            "Top of the band the model sees, as a share of the image's height"
          )
        ]
      }),
      VisionCore.Segmentation.step(state.name, "classes", "Classes", 103, %{
        summary: "Sorts the stereo points seen in the band into road and off-road.",
        explanation:
          "Projects the depth of the stereo pair captured closest to the image into the " <>
            "camera's image, through its calibration and its pose relative to the stereo " <>
            "pair, and sorts each point by the class of the part of the band it lands in: " <>
            "road for the classes in road_classes, off-road for every other. Points outside " <>
            "the band are left out. Fixed in the build: road_classes; reprojection_stride, " <>
            "every how many pixels and rows of the depth it projects, a higher value sorting " <>
            "faster and fewer points; and pair_wait_ms, how long the classes wait for that " <>
            "pair. Without a pair, or without the camera's calibration or pose, the classes " <>
            "are published without points.",
        compute: @on_the_beam,
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
    state = %{state | camera: CameraDepth.add_pair(state.camera, pair)}

    case state.awaiting do
      nil -> {:noreply, state}
      awaiting -> {:noreply, publish_awaiting(awaiting, state, final: false)}
    end
  end

  # A frame that comes while a label image waits for its pair is skipped, as one during an inference.
  def handle_cast({:camera_frame, %Frame{}}, %{awaiting: %{}} = state), do: {:noreply, state}

  def handle_cast({:camera_frame, %Frame{} = frame}, state) do
    frame_count = state.frame_count + 1
    state = %{state | frame_count: frame_count}

    cond do
      rem(frame_count, state.segment_every_n) != 0 -> {:noreply, state}
      not is_binary(frame.rgb) -> {:noreply, note_colourless(state)}
      true -> {:noreply, submit(frame, state)}
    end
  end

  def handle_cast(_message, state), do: {:noreply, state}

  defp submit(frame, state) do
    {_x, top, width, height} = band = band(frame.width, frame.height, state.band_top)
    rgb = binary_part(frame.rgb, top * width * 3, height * width * 3)
    sequence = state.sequence + 1

    case state.backend.segment(state.backend_server, sequence, %{
           width: width,
           height: height,
           rgb: rgb
         }) do
      :ok -> %{state | sequence: sequence, pending: %{frame: %{frame | rgb: nil}, band: band}}
      # Busy or unavailable: the backend logs the unavailable case once.
      {:error, _reason} -> state
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
        %{sequence: sequence, pending: %{frame: frame, band: band}} = state
      ) do
    state = %{state | pending: nil}

    cond do
      is_nil(labels) ->
        {:noreply, state}

      CameraDepth.projectable?(state.camera) ->
        awaiting = %{frame: frame, labels: Map.put(labels, :band, band), timer: nil}
        {:noreply, publish_awaiting(awaiting, state, final: false)}

      true ->
        publish(state, frame, Map.put(labels, :band, band), nil)
        {:noreply, state}
    end
  end

  # A reply for a frame no longer waited on.
  def handle_info({:inference_labels, _stale, _labels}, state), do: {:noreply, state}

  def handle_info({:pair_wait, timer}, %{awaiting: %{timer: timer} = awaiting} = state),
    do: {:noreply, publish_awaiting(awaiting, state, final: true)}

  def handle_info(_message, state), do: {:noreply, state}

  # Publishes a frame's label image once its pair is known, or waits for it, at most :pair_wait_ms.
  defp publish_awaiting(%{frame: frame} = awaiting, state, final: final) do
    case CameraDepth.match(state.camera, frame.capture_ns, final: final) do
      :wait when is_nil(awaiting.timer) ->
        timer = make_ref()
        Process.send_after(self(), {:pair_wait, timer}, state.pair_wait_ms)
        %{state | awaiting: %{awaiting | timer: timer}}

      :wait ->
        %{state | awaiting: awaiting}

      {:ok, pair} ->
        {clouds, state} = clouds(awaiting, pair, note_match(state, pair))
        publish(state, frame, awaiting.labels, clouds)
        %{state | awaiting: nil}

      :none ->
        state = note_match(state, nil)
        publish(state, frame, awaiting.labels, nil)
        %{state | awaiting: nil}
    end
  end

  defp clouds(%{frame: frame, labels: labels}, pair, state) do
    {lens, camera} = CameraDepth.lens(state.camera, {frame.width, frame.height})
    state = %{state | camera: camera}

    if lens do
      %{points: points} =
        Reprojection.project_with_origin(pair, lens, camera.pose, state.reprojection_stride)

      {road, off_road} = sort_points(points, labels, state.road, <<>>, <<>>)
      {%{road: road, off_road: off_road, frame_id: Pair.frame_id(pair)}, state}
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

  defp note_match(%{unmatched_logged: false} = state, nil) do
    Logger.warning(
      "segmentation pipeline #{state.name}: no stereo pair captured close enough to the " <>
        "camera #{state.camera.name}'s image, so its segmentation has no clouds until one is"
    )

    %{state | unmatched_logged: true}
  end

  defp note_match(state, nil), do: state
  defp note_match(state, _pair), do: %{state | unmatched_logged: false}

  defp publish(state, frame, labels, clouds),
    do:
      Outputs.publish(
        {:segmentation, Detection.server(__MODULE__, state.name)},
        {:segmentation, state.name, frame, labels, clouds}
      )
end

defmodule VisionCore.Detection.CameraSource do
  @moduledoc """
  What a `VisionCore.Detection.Pipeline` whose source is a camera of its
  own (`source: {:camera, name}`) needs to place its boxes: the camera's
  calibration and pose, read once at start, the stereo pairs to take the
  depth from, and the placement itself.

  ## Matching a frame with a pair

  The last 4 pairs are kept. A frame is matched with the pair whose left
  capture time is closest to its own, within half the pair period, the
  median spacing of the pairs kept; otherwise it has no depth, rather
  than a stale one. The stereo pipeline publishes a pair well after its
  capture, so the pair captured closest to a frame may come after the
  frame's boxes: `match/3` says `:wait` until a pair captured at or after
  the frame has come, and the pipeline waits for it at most its
  `:pair_wait_ms`, skipping the camera's frames meanwhile, then matches
  with the pairs it has (`match/3` with `final: true`).

  ## Placing a box

  The camera's calibration is scaled to each frame size it sees
  (`VisionCore.Ros2.CameraCalibration.scale_to/3`) and read once for that
  size (`VisionCore.Detection.Reprojection.lens/1`). The matched pair's
  depth is projected into the frame (`Reprojection.project/4`, every
  `:reprojection_stride`-th pixel and row), each box takes the median
  depth of the points inside its middle (`Fusion.projected_depths/3`)
  and is placed through the lens (`Fusion.unproject_camera/3`). A box
  without a distance, with no point inside it, no matched pair, no pose
  or no calibration, or 90° or more off-axis, is kept with `nil` `:x`,
  `:y`, `:z`, `:width`, `:height` and `:depth`. Each box has the
  `:bearing` of its centre, `{azimuth, elevation}` in radians in the
  camera's optical frame, azimuth positive to the right and elevation
  positive up (`Reprojection.bearing/2`), `nil` without a calibration
  or past the lens's fold.
  """
  require Logger

  alias VisionCore.Camera.{Frame, Pose, Unit}
  alias VisionCore.Detection.{Fusion, Reprojection}
  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Stereo.Pair

  @kept_pairs 4

  defstruct [:name, :server, :calibration, :pose, lenses: %{}, pairs: []]

  @typedoc """
  The camera `name`, the name its driver publishes under, its calibration
  and pose, `nil` without, its lens by frame size, `nil` for a size its
  calibration cannot be projected at, and the last pairs, newest first.
  """
  @type t :: %__MODULE__{
          name: atom(),
          server: atom(),
          calibration: CameraCalibration.t() | nil,
          pose: Pose.t() | nil,
          lenses: %{{pos_integer(), pos_integer()} => Reprojection.lens() | nil},
          pairs: [Pair.t()]
        }

  @doc """
  The camera `name` of `config`, its calibration and pose read, each
  missing one logged once as a warning naming `pipeline`. Raises
  `ArgumentError` when `config` has no camera `name`.
  """
  @spec new(atom(), VisionCore.Config.t(), atom()) :: t()
  def new(name, config, pipeline) do
    settings =
      Enum.find(Unit.settings(config), &(&1.name == name)) ||
        raise ArgumentError,
              "its source names the camera #{inspect(name)}, which is no camera of the " <>
                "configuration"

    %__MODULE__{
      name: name,
      server: settings.server,
      calibration: read(:calibration, settings.calibration_path, pipeline, name),
      pose: read(:pose, settings.pose_path, pipeline, name)
    }
  end

  defp read(kind, nil, pipeline, name) do
    Logger.warning(
      "detection pipeline #{pipeline}: camera #{name} has no #{kind}, " <>
        "so its detections have no distance#{if kind == :calibration, do: " nor bearing"}"
    )

    nil
  end

  defp read(kind, path, pipeline, name) do
    case load(kind, path) do
      {:ok, value} ->
        value

      {:error, reason} ->
        Logger.warning(
          "detection pipeline #{pipeline}: camera #{name} has no #{kind}, #{path} " <>
            "unreadable (#{inspect(reason)}), so its detections have no distance"
        )

        nil
    end
  end

  defp load(:calibration, path), do: CameraCalibration.load(path)
  defp load(:pose, path), do: Pose.load(path)

  @doc "Whether boxes can be placed in 3D: the camera has a calibration and a pose."
  @spec placeable?(t()) :: boolean()
  def placeable?(source), do: not is_nil(source.calibration) and not is_nil(source.pose)

  @doc "Keeps `pair` among the last pairs, when it has a depth map."
  @spec add_pair(t(), Pair.t()) :: t()
  def add_pair(source, %Pair{depth: depth, geometry: geometry} = pair)
      when is_binary(depth) and is_map(geometry),
      do: %{source | pairs: Enum.take([pair | source.pairs], @kept_pairs)}

  def add_pair(source, _pair_without_depth), do: source

  @doc """
  The pair to place the boxes of a frame captured at `capture_ns` with:
  `{:ok, pair}`, `:none` when no pair kept was captured within half the
  pair period, or `:wait` while a pair captured at or after the frame
  may still come; with `final: true`, never `:wait`.
  """
  @spec match(t(), integer(), keyword()) :: {:ok, Pair.t()} | :none | :wait
  def match(source, capture_ns, opts \\ []) do
    final? = Keyword.get(opts, :final, false)

    case source.pairs do
      [newest | _older] = pairs ->
        if final? or Pair.capture_ns(newest) >= capture_ns,
          do: closest(pairs, capture_ns),
          else: :wait

      [] ->
        if final?, do: :none, else: :wait
    end
  end

  defp closest(pairs, capture_ns) do
    pair = Enum.min_by(pairs, &abs(Pair.capture_ns(&1) - capture_ns))

    case period_ns(pairs) do
      nil ->
        :none

      period ->
        if abs(Pair.capture_ns(pair) - capture_ns) * 2 <= period, do: {:ok, pair}, else: :none
    end
  end

  defp period_ns([_one]), do: nil

  defp period_ns(pairs) do
    spacings =
      pairs
      |> Enum.map(&Pair.capture_ns/1)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [newer, older] -> newer - older end)
      |> Enum.sort()

    Enum.at(spacings, div(length(spacings), 2))
  end

  @doc """
  `detections`, boxes in `frame`'s pixels, placed with `pair`'s depth,
  `nil` for none, each sampled in its central `fraction` from every
  `stride`-th projected pixel (see the moduledoc), with their `:bearing`.
  Returns them with the source, which keeps the lens of `frame`'s size.
  """
  @spec place(t(), [map()], Frame.t(), Pair.t() | nil, float(), pos_integer()) ::
          {[map()], t()}
  def place(source, detections, %Frame{} = frame, pair, fraction, stride) do
    {lens, source} = lens(source, {frame.width, frame.height})
    distances = distances(lens, source.pose, detections, pair, fraction, stride)

    placed =
      Enum.zip_with(detections, distances, fn detection, distance ->
        detection
        |> Map.merge(position(lens, detection, distance))
        |> Map.put(:bearing, bearing(lens, detection))
      end)

    {placed, source}
  end

  defp lens(%{calibration: nil} = source, _size), do: {nil, source}

  defp lens(source, size) when is_map_key(source.lenses, size),
    do: {source.lenses[size], source}

  defp lens(source, {width, height} = size) do
    calibration = CameraCalibration.scale_to(source.calibration, width, height)

    lens =
      case Reprojection.check(calibration) do
        :ok ->
          Reprojection.lens(calibration)

        {:error, message} ->
          Logger.warning(
            "camera #{source.name}: its calibration cannot place detections at " <>
              "#{width}x#{height}: #{message}"
          )

          nil
      end

    {lens, put_in(source.lenses[size], lens)}
  end

  defp distances(lens, pose, detections, %Pair{depth: depth} = pair, fraction, stride)
       when not is_nil(lens) and not is_nil(pose) and is_binary(depth) do
    pair
    |> Reprojection.project(lens, pose, stride)
    |> Fusion.projected_depths(Enum.map(detections, & &1.box), fraction)
  end

  defp distances(_lens, _pose, detections, _pair, _fraction, _stride),
    do: Enum.map(detections, fn _detection -> nil end)

  defp position(lens, detection, distance) when is_float(distance) do
    case Fusion.unproject_camera(detection.box, distance, lens) do
      nil -> no_position()
      position -> Map.put(position, :depth, 0.1)
    end
  end

  defp position(_lens, _detection, nil), do: no_position()

  defp no_position, do: %{x: nil, y: nil, z: nil, width: nil, height: nil, depth: nil}

  defp bearing(nil, _detection), do: nil

  defp bearing(lens, %{box: box}),
    do: Reprojection.bearing(lens, {(box.x0 + box.x1) / 2, (box.y0 + box.y1) / 2})

  @doc "The outline of `box` in the camera's pixels: its four corners, top-left first."
  @spec outline(map()) :: [{number(), number()}]
  def outline(box), do: [{box.x0, box.y0}, {box.x1, box.y0}, {box.x1, box.y1}, {box.x0, box.y1}]
end

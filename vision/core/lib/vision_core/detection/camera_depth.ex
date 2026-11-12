defmodule VisionCore.Detection.CameraDepth do
  @moduledoc """
  The stereo depth a pipeline on a camera of its own
  (`source: {:camera, name}`) takes: the camera's calibration and pose,
  read once at start, its lens for each frame size, and the stereo pairs
  matched with its frames. `VisionCore.Detection.CameraSource` places a
  detection pipeline's boxes with it, and `VisionCore.Segmentation.Pipeline`
  classes a segmentation pipeline's points with it.

  ## Matching a frame with a pair

  The last 4 pairs are kept. A frame is matched with the pair whose left
  capture time is closest to its own, within half the pair period, the
  median spacing of the pairs kept; otherwise it has no depth, rather
  than a stale one. The stereo pipeline publishes a pair well after its
  capture, so the pair captured closest to a frame may come after the
  frame's result: `match/3` says `:wait` until a pair captured at or
  after the frame has come, and the pipeline waits for it at most its
  `:pair_wait_ms` (`VisionCore.Detection.DepthQueue`), skipping the
  camera's frames meanwhile, then matches with the pairs it has
  (`match/3` with `final: true`).

  ## The lens

  The camera's calibration is scaled to each frame size it sees
  (`VisionCore.Ros2.CameraCalibration.scale_to/3`) and read once for that
  size (`VisionCore.Detection.Reprojection.lens/1`).
  """
  require Logger

  alias VisionCore.Camera.{Pose, Unit}
  alias VisionCore.Detection.Reprojection
  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Stereo.Pair

  @kept_pairs 4

  defstruct [:name, :server, :calibration, :pose, :owner, :wording, lenses: %{}, pairs: []]

  @typedoc """
  What the owner's warnings say is lost: without a calibration, without a
  pose, with either unreadable, and without a matched pair, and what a
  calibration that cannot be projected with cannot do.
  """
  @type wording :: %{
          calibration: String.t(),
          pose: String.t(),
          unreadable: String.t(),
          unmatched: String.t(),
          lens: String.t()
        }

  @typedoc """
  The camera `name`, the name its driver publishes under, its calibration
  and pose, `nil` without, the owner its warnings name and their wording,
  its lens by frame size, `nil` for a size its calibration cannot be
  projected at, and the last pairs, newest first.
  """
  @type t :: %__MODULE__{
          name: atom(),
          server: atom(),
          calibration: CameraCalibration.t() | nil,
          pose: Pose.t() | nil,
          owner: String.t(),
          wording: wording(),
          lenses: %{{pos_integer(), pos_integer()} => Reprojection.lens() | nil},
          pairs: [Pair.t()]
        }

  @doc """
  The camera `name` of `config`, its calibration and pose read, each
  missing or unreadable one logged once as a warning naming `owner` and
  saying what is lost (`wording`). Raises `ArgumentError` when `config`
  has no camera `name`.
  """
  @spec new(atom(), VisionCore.Config.t(), String.t(), wording()) :: t()
  def new(name, config, owner, wording) do
    settings =
      Enum.find(Unit.settings(config), &(&1.name == name)) ||
        raise ArgumentError,
              "its source names the camera #{inspect(name)}, which is no camera of the " <>
                "configuration"

    depth = %__MODULE__{name: name, server: settings.server, owner: owner, wording: wording}

    %{
      depth
      | calibration: read(depth, :calibration, settings.calibration_path),
        pose: read(depth, :pose, settings.pose_path)
    }
  end

  defp read(depth, kind, nil) do
    Logger.warning(
      "#{depth.owner}: camera #{depth.name} has no #{kind}, so #{Map.fetch!(depth.wording, kind)}"
    )

    nil
  end

  defp read(depth, kind, path) do
    case load(kind, path) do
      {:ok, value} ->
        value

      {:error, reason} ->
        Logger.warning(
          "#{depth.owner}: camera #{depth.name} has no #{kind}, #{path} " <>
            "unreadable (#{inspect(reason)}), so #{depth.wording.unreadable}"
        )

        nil
    end
  end

  defp load(:calibration, path), do: CameraCalibration.load(path)
  defp load(:pose, path), do: Pose.load(path)

  @doc "Whether the depth can be projected into the camera: it has a calibration and a pose."
  @spec projectable?(t()) :: boolean()
  def projectable?(depth), do: not is_nil(depth.calibration) and not is_nil(depth.pose)

  @doc "Keeps `pair` among the last pairs, when it has a depth map."
  @spec add_pair(t(), Pair.t()) :: t()
  def add_pair(depth, %Pair{depth: depth_map, geometry: geometry} = pair)
      when is_binary(depth_map) and is_map(geometry),
      do: %{depth | pairs: Enum.take([pair | depth.pairs], @kept_pairs)}

  def add_pair(depth, _pair_without_depth), do: depth

  @doc """
  The pair to take the depth of a frame captured at `capture_ns` from:
  `{:ok, pair}`, `:none` when no pair kept was captured within half the
  pair period, or `:wait` while a pair captured at or after the frame
  may still come; with `final: true`, never `:wait`.
  """
  @spec match(t(), integer(), keyword()) :: {:ok, Pair.t()} | :none | :wait
  def match(depth, capture_ns, opts \\ []) do
    final? = Keyword.get(opts, :final, false)

    case depth.pairs do
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
  The camera's lens at frames of `size`, `{width, height}`: `nil`
  without a calibration, or with one that cannot be projected at that
  size, which is logged once. Returns it with the depth, which keeps it.
  """
  @spec lens(t(), {pos_integer(), pos_integer()}) :: {Reprojection.lens() | nil, t()}
  def lens(%{calibration: nil} = depth, _size), do: {nil, depth}

  def lens(depth, size) when is_map_key(depth.lenses, size), do: {depth.lenses[size], depth}

  def lens(depth, {width, height} = size) do
    calibration = CameraCalibration.scale_to(depth.calibration, width, height)

    lens =
      case Reprojection.check(calibration) do
        :ok ->
          Reprojection.lens(calibration)

        {:error, message} ->
          Logger.warning(
            "camera #{depth.name}: its calibration cannot #{depth.wording.lens} at " <>
              "#{width}x#{height}: #{message}"
          )

          nil
      end

    {lens, put_in(depth.lenses[size], lens)}
  end
end

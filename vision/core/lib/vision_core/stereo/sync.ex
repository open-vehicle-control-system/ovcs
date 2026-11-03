defmodule VisionCore.Stereo.Sync do
  @moduledoc """
  How far apart a stereo unit's two cameras capture: right minus left,
  measured on every pair of frames taken less than half a frame period
  apart, on the second frame of the two to arrive, and summarised over
  the recent pairs.

  `VisionCore.Stereo.Pairer` measures it on every frame its cameras
  deliver, for `VisionCore.Status`; the ROS 2 exporter's diagnostics
  (`VisionCore.Ros2.Exporter.Diagnostics`) measure their own with
  `pair_offset/4`.
  """

  @recent_frame_count 4
  @window_size 150
  @stale_ms 2_000

  @enforce_keys [:half_period_ns]
  defstruct [:half_period_ns, recent: %{left: [], right: []}, offsets_ms: [], last_pair_ms: nil]

  @typedoc """
  A measurement: the capture times of each camera's recent frames, the
  recent offsets in ms, newest first, and when the last pair formed.
  """
  @type t :: %__MODULE__{
          half_period_ns: pos_integer(),
          recent: %{left: [integer()], right: [integer()]},
          offsets_ms: [float()],
          last_pair_ms: integer() | nil
        }

  @typedoc """
  The recent pairs' median and largest offset in ms, `nil` without
  pairs, and how many pairs they are.
  """
  @type summary :: %{
          offset_median_ms: float() | nil,
          offset_max_ms: float() | nil,
          pairs: non_neg_integer()
        }

  @doc "A measurement of cameras capturing `fps` frames a second."
  @spec new(pos_integer()) :: t()
  def new(fps), do: %__MODULE__{half_period_ns: div(1_000_000_000, 2 * fps)}

  @doc """
  `sync` with the frame of `side` captured at `capture_ns`, arrived at
  `now_ms` (monotonic), and the offset in ms it forms with the other
  camera's recent frames, `nil` when it forms no pair.
  """
  @spec add(t(), :left | :right, integer(), integer()) :: {float() | nil, t()}
  def add(%__MODULE__{} = sync, side, capture_ns, now_ms) do
    other_side = if side == :left, do: :right, else: :left
    recent = Map.update!(sync.recent, side, &Enum.take([capture_ns | &1], @recent_frame_count))
    sync = %{sync | recent: recent}

    case pair_offset(side, capture_ns, sync.recent[other_side], sync.half_period_ns) do
      nil ->
        {nil, sync}

      offset_ns ->
        offset_ms = offset_ns / 1.0e6
        offsets_ms = Enum.take([offset_ms | sync.offsets_ms], @window_size)
        {offset_ms, %{sync | offsets_ms: offsets_ms, last_pair_ms: now_ms}}
    end
  end

  @doc """
  The recent pairs at `now_ms`; none before the first pair, and none
  once the last one formed more than two seconds before, as when the
  cameras stopped.
  """
  @spec summary(t(), integer()) :: summary()
  def summary(%__MODULE__{last_pair_ms: last_pair_ms} = sync, now_ms)
      when is_integer(last_pair_ms) and now_ms - last_pair_ms <= @stale_ms do
    %{
      offset_median_ms: median(sync.offsets_ms),
      offset_max_ms: Enum.max_by(sync.offsets_ms, &abs/1),
      pairs: length(sync.offsets_ms)
    }
  end

  def summary(%__MODULE__{}, _now_ms), do: %{offset_median_ms: nil, offset_max_ms: nil, pairs: 0}

  @doc """
  Right minus left capture time of the frame at `capture_ns` and the
  nearest of the other camera's `recent` frames, or nil when none is
  within `half_period_ns`.
  """
  @spec pair_offset(:left | :right, integer(), [integer()], pos_integer()) :: integer() | nil
  def pair_offset(side, capture_ns, recent, half_period_ns) do
    case Enum.min_by(recent, &abs(&1 - capture_ns), fn -> nil end) do
      nil -> nil
      other_capture_ns when abs(other_capture_ns - capture_ns) >= half_period_ns -> nil
      other_capture_ns when side == :right -> capture_ns - other_capture_ns
      other_capture_ns -> other_capture_ns - capture_ns
    end
  end

  @doc "The middle value of `values`, the upper one of an even count."
  @spec median([number(), ...]) :: number()
  def median(values) do
    sorted = Enum.sort(values)
    Enum.at(sorted, div(length(sorted), 2))
  end
end

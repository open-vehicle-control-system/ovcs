defmodule VisionCore.Camera.VideoQueue do
  @moduledoc """
  The frames of a camera's H.264 output (`VisionCore.Camera.Output`) a
  consumer has yet to take, in their order, at most `limit` of them.

  A decoder needs every frame of the stream from a key frame on, so a
  queue never hands over a frame whose key frame it dropped: it starts
  at a key frame, the frames before the first one dropped, and a frame
  that comes while it holds `limit` frames empties it, the frames that
  follow dropped until the next key frame. A consumer that falls behind
  skips whole groups of frames instead of holding a growing backlog.
  """

  @enforce_keys [:limit]
  defstruct [:limit, frames: :queue.new(), size: 0, synced?: false]

  @type t :: %__MODULE__{
          limit: pos_integer(),
          frames: :queue.queue(VisionCore.Camera.Frame.t()),
          size: non_neg_integer(),
          synced?: boolean()
        }

  @doc "An empty queue holding at most `limit` frames, waiting for a key frame."
  @spec new(pos_integer()) :: t()
  def new(limit) when is_integer(limit) and limit > 0,
    do: %__MODULE__{limit: limit, frames: :queue.new()}

  @doc "`queue` with `frame` at its end, or without the frames it drops; see the module doc."
  @spec push(t(), VisionCore.Camera.Frame.t()) :: t()
  def push(%__MODULE__{size: size, limit: limit} = queue, frame) when size >= limit,
    do: push(%{queue | frames: :queue.new(), size: 0, synced?: false}, frame)

  def push(%__MODULE__{synced?: false} = queue, %{keyframe?: false}), do: queue

  def push(%__MODULE__{} = queue, frame),
    do: %{queue | frames: :queue.in(frame, queue.frames), size: queue.size + 1, synced?: true}

  @doc "The frame at the head of `queue` and the queue without it, or `:empty`."
  @spec pop(t()) :: {:ok, VisionCore.Camera.Frame.t(), t()} | :empty
  def pop(%__MODULE__{} = queue) do
    case :queue.out(queue.frames) do
      {{:value, frame}, frames} -> {:ok, frame, %{queue | frames: frames, size: queue.size - 1}}
      {:empty, _frames} -> :empty
    end
  end

  @doc "How many frames `queue` holds."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size
end

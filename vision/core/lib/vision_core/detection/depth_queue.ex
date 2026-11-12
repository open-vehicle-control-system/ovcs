defmodule VisionCore.Detection.DepthQueue do
  @moduledoc """
  The results of a camera's frames waiting for the stereo pair to take
  their depth from, which a pipeline on a camera of its own keeps
  (`VisionCore.Detection.Pipeline`, `VisionCore.Segmentation.Pipeline`).

  A result waits for its pair (`VisionCore.Detection.CameraDepth.match/3`)
  at most `pair_wait_ms` from when it is put, then takes the pairs it
  has. `settle/3` gives back the results whose pair is known, oldest
  first, and `schedule/2` has the owner told when to settle again
  without a new pair.
  """
  require Logger

  alias VisionCore.Detection.CameraDepth
  alias VisionCore.Stereo.Pair

  @ns_per_ms 1_000_000

  defstruct [:pair_wait_ms, entries: :queue.new(), timer: nil, unmatched_logged: false]

  @typedoc """
  The longest wait, the results waiting, oldest first, the timer armed
  for the first one's deadline, and whether a result without a pair
  was logged since the last one with.
  """
  @type t :: %__MODULE__{
          pair_wait_ms: non_neg_integer(),
          entries: :queue.queue(map()),
          timer: {reference(), integer()} | nil,
          unmatched_logged: boolean()
        }

  @doc "An empty queue whose results wait at most `pair_wait_ms` for their pair."
  @spec new(non_neg_integer()) :: t()
  def new(pair_wait_ms), do: %__MODULE__{pair_wait_ms: pair_wait_ms}

  @doc "Whether a result waits."
  @spec waiting?(t()) :: boolean()
  def waiting?(queue), do: not :queue.is_empty(queue.entries)

  @doc """
  `queue` with `result`, of a frame captured at `capture_ns`, waiting
  for its pair from `now_ns` on.
  """
  @spec put(t(), term(), integer(), integer()) :: t()
  def put(queue, result, capture_ns, now_ns) do
    entry = %{
      result: result,
      capture_ns: capture_ns,
      deadline_ns: now_ns + queue.pair_wait_ms * @ns_per_ms
    }

    %{queue | entries: :queue.in(entry, queue.entries)}
  end

  @doc """
  The results whose pair is known at `now_ns`, oldest first, each with
  its pair, `nil` for none, and the queue without them. A result past
  its deadline takes the pairs `depth` has. The first result without a
  pair since one with is logged as a warning naming `depth`'s owner.
  """
  @spec settle(t(), CameraDepth.t(), integer()) :: {[{term(), Pair.t() | nil}], t()}
  def settle(queue, depth, now_ns), do: settle(queue, depth, now_ns, [])

  defp settle(queue, depth, now_ns, settled) do
    with {:value, entry} <- :queue.peek(queue.entries),
         {:ok, pair} <- matched(depth, entry, now_ns) do
      queue = %{note_match(queue, depth, pair) | entries: :queue.drop(queue.entries)}
      settle(queue, depth, now_ns, [{entry.result, pair} | settled])
    else
      _empty_or_waiting -> {Enum.reverse(settled), queue}
    end
  end

  defp matched(depth, entry, now_ns) do
    case CameraDepth.match(depth, entry.capture_ns, final: now_ns >= entry.deadline_ns) do
      {:ok, pair} -> {:ok, pair}
      :none -> {:ok, nil}
      :wait -> :wait
    end
  end

  defp note_match(%{unmatched_logged: false} = queue, depth, nil) do
    Logger.warning(
      "#{depth.owner}: no stereo pair captured close enough to the camera #{depth.name}'s " <>
        "image, so #{depth.wording.unmatched} until one is"
    )

    %{queue | unmatched_logged: true}
  end

  defp note_match(queue, _depth, nil), do: queue
  defp note_match(queue, _depth, _pair), do: %{queue | unmatched_logged: false}

  @doc """
  Has `:pair_wait` sent to the calling process at the first result's
  deadline, for it to settle the queue again, and cancels a timer armed
  for another; `now_ns` is the time now.
  """
  @spec schedule(t(), integer()) :: t()
  def schedule(queue, now_ns) do
    case {:queue.peek(queue.entries), queue.timer} do
      {{:value, %{deadline_ns: deadline}}, {_timer, deadline}} ->
        queue

      {{:value, %{deadline_ns: deadline}}, _other} ->
        cancel(queue.timer)
        delay_ms = max(ceil((deadline - now_ns) / @ns_per_ms), 0)
        %{queue | timer: {Process.send_after(self(), :pair_wait, delay_ms), deadline}}

      {:empty, _timer} ->
        cancel(queue.timer)
        %{queue | timer: nil}
    end
  end

  defp cancel(nil), do: :ok
  defp cancel({timer, _deadline}), do: Process.cancel_timer(timer)
end

defmodule VisionCore.CameraDepth.Queue do
  @moduledoc """
  The results of a camera's frames waiting for the stereo pair to take
  their depth from, oldest first, which a pipeline on a camera of its
  own keeps (`VisionCore.Detection.Pipeline`,
  `VisionCore.Segmentation.Pipeline`), so that the camera's frames keep
  going to the model while the stereo pipeline, slower, catches up.

  `settle/3` gives back, in the order they were put, the results whose
  pair is known (`VisionCore.CameraDepth.match/3`): a result
  waits for its pair at most `pair_wait_ms` from when it is put, and
  not at all while the stereo pairs have stalled
  (`VisionCore.CameraDepth.stalled?/2`), then takes the pairs
  there are. A result that needs no depth leaves once the results put
  before it have. `schedule/3` has the owner told when to settle again
  without a new pair.

  With 32 results waiting the queue is full (`admit/2`), and the owner
  skips the camera's frames until one leaves: every result kept can
  still be given its pair, and the frames held stay few.
  """
  require Logger

  alias VisionCore.CameraDepth
  alias VisionCore.Stereo.Pair

  @ns_per_ms 1_000_000
  @max_waiting 32

  defstruct [
    :pair_wait_ms,
    entries: :queue.new(),
    timer: nil,
    unmatched_logged: false,
    full_logged: false
  ]

  @typedoc """
  The longest wait, the results waiting, oldest first, each with its
  frame's capture time, `nil` for one that needs no depth, and its
  deadline, the timer armed and when it fires, and whether a result
  without a pair was logged since the last one with, and a full queue
  since it last had room.
  """
  @type t :: %__MODULE__{
          pair_wait_ms: non_neg_integer(),
          entries: :queue.queue(map()),
          timer: {reference(), integer()} | nil,
          unmatched_logged: boolean(),
          full_logged: boolean()
        }

  @doc "An empty queue whose results wait at most `pair_wait_ms` for their pair."
  @spec new(non_neg_integer()) :: t()
  def new(pair_wait_ms), do: %__MODULE__{pair_wait_ms: pair_wait_ms, entries: :queue.new()}

  @doc """
  `:ok` when the queue has room for the result of another of the
  camera's frames, `:full` with #{@max_waiting} results waiting, and the
  queue. The first `:full` since the queue had room is logged as a
  warning naming `depth`'s owner.
  """
  @spec admit(t(), CameraDepth.t()) :: {:ok | :full, t()}
  def admit(queue, depth) do
    cond do
      :queue.len(queue.entries) < @max_waiting ->
        {:ok, %{queue | full_logged: false}}

      queue.full_logged ->
        {:full, queue}

      true ->
        Logger.warning(
          "#{depth.owner}: #{@max_waiting} of the camera #{depth.name}'s images wait for their " <>
            "stereo pair, so its next images are skipped until one has it"
        )

        {:full, %{queue | full_logged: true}}
    end
  end

  @doc """
  `queue` with `result`, of a frame captured at `capture_ns`, waiting
  for its pair from `now_ns` on.
  """
  @spec put(t(), term(), integer(), integer()) :: t()
  def put(queue, result, capture_ns, now_ns) do
    deadline_ns = now_ns + queue.pair_wait_ms * @ns_per_ms
    entry = %{result: result, capture_ns: capture_ns, deadline_ns: deadline_ns}
    %{queue | entries: :queue.in(entry, queue.entries)}
  end

  @doc "`queue` with `result`, which needs no depth, after the results waiting."
  @spec put_without_depth(t(), term()) :: t()
  def put_without_depth(queue, result) do
    entry = %{result: result, capture_ns: nil, deadline_ns: nil}
    %{queue | entries: :queue.in(entry, queue.entries)}
  end

  @doc """
  The results that leave the queue at `now_ns`, oldest first, each with
  its pair, `nil` for none, and the queue without them. The first result
  without a pair since one with one is logged as a warning naming
  `depth`'s owner.
  """
  @spec settle(t(), CameraDepth.t(), integer()) :: {[{term(), Pair.t() | nil}], t()}
  def settle(queue, depth, now_ns), do: settle(queue, depth, now_ns, [])

  defp settle(queue, depth, now_ns, settled) do
    with {:value, entry} <- :queue.peek(queue.entries),
         {:ok, pair} <- matched(depth, entry, now_ns) do
      queue = %{note_match(queue, depth, entry, pair) | entries: :queue.drop(queue.entries)}
      settle(queue, depth, now_ns, [{entry.result, pair} | settled])
    else
      _empty_or_waiting -> {Enum.reverse(settled), queue}
    end
  end

  defp matched(_depth, %{capture_ns: nil}, _now_ns), do: {:ok, nil}

  defp matched(depth, entry, now_ns) do
    final? = now_ns >= entry.deadline_ns or CameraDepth.stalled?(depth, now_ns)

    case CameraDepth.match(depth, entry.capture_ns, final: final?) do
      {:ok, pair} -> {:ok, pair}
      :none -> {:ok, nil}
      :wait -> :wait
    end
  end

  defp note_match(queue, _depth, %{capture_ns: nil}, nil), do: queue

  defp note_match(%{unmatched_logged: false} = queue, depth, _entry, nil) do
    Logger.warning(
      "#{depth.owner}: no stereo pair captured close enough to the camera #{depth.name}'s " <>
        "image, so #{depth.wording.unmatched} until one is"
    )

    %{queue | unmatched_logged: true}
  end

  defp note_match(queue, _depth, _entry, nil), do: queue
  defp note_match(queue, _depth, _entry, _pair), do: %{queue | unmatched_logged: false}

  @doc """
  Has `:pair_wait` sent to the calling process when the first result
  waiting leaves without a new pair, at its deadline or when `depth`'s
  pairs stall, whichever comes first, for it to settle the queue again;
  cancels a timer armed for another time, and arms again one that has
  fired. `now_ns` is the time now.
  """
  @spec schedule(t(), CameraDepth.t(), integer()) :: t()
  def schedule(queue, depth, now_ns) do
    case {wake_ns(queue, depth), queue.timer} do
      {wake_ns, {timer, wake_ns}} when is_integer(wake_ns) ->
        if Process.read_timer(timer), do: queue, else: arm(queue, wake_ns, now_ns)

      {nil, timer} ->
        cancel(timer)
        %{queue | timer: nil}

      {wake_ns, timer} ->
        cancel(timer)
        arm(queue, wake_ns, now_ns)
    end
  end

  defp arm(queue, wake_ns, now_ns) do
    delay_ms = max(ceil((wake_ns - now_ns) / @ns_per_ms), 0)
    %{queue | timer: {Process.send_after(self(), :pair_wait, delay_ms), wake_ns}}
  end

  defp wake_ns(queue, depth) do
    case :queue.peek(queue.entries) do
      {:value, %{deadline_ns: deadline_ns}} when is_integer(deadline_ns) ->
        min(deadline_ns, CameraDepth.stalls_at(depth) || deadline_ns)

      _empty_or_ready ->
        nil
    end
  end

  defp cancel(nil), do: :ok
  defp cancel({timer, _wake_ns}), do: Process.cancel_timer(timer)
end

defmodule RosBridge.Clock do
  @moduledoc """
  What `use_sim_time` means for this bridge.

  Every publisher stamps its output through
  `RosBridge.Timing.time_message_for/1`, which projects a driver's
  Erlang-monotonic capture time onto wall clock. On a vehicle that is
  right. Against a simulator it is not: Gazebo owns the clock, starts
  it at zero, and advances it with physics, so a wall-clock stamp is
  most of two decades away from everything else on the graph.

  That mattered less than it sounds until something consumed the
  stamps. `RosBridge.Camera.Zenoh` documents the trade-off and
  accepted it — pairing left and right frames only needs them to agree
  with *each other*. Nav2 is the first consumer that needs them to
  agree with **`/tf`**, and it does not: its costmap message filter
  drops every point cloud with

      the timestamp on the message is earlier than all the data in
      the transform cache

  ## How it follows the simulator

  Not by passing simulator stamps through. `Frame.capture_ns` means
  Erlang monotonic time everywhere in this bridge — `Timing` is built
  on that and converts foreign clocks at the driver boundary — and
  breaking that invariant to suit one consumer would trade a bounded
  problem for an unbounded one.

  Instead this tracks the *offset* between the two timescales. Each
  `/clock` sample gives a simulator time and, read alongside it, a
  local monotonic time; the difference is the offset, and any
  monotonic timestamp projects through it. Drivers keep producing
  monotonic time, `Timing` keeps being the only place that converts,
  and the conversion simply targets a different clock.

  ## Drift, and why it is small

  The offset is exact only at the instant it was sampled. If the
  simulator runs at other than real time the two clocks diverge
  between samples, at a rate of `|1 - sim_rate|`. Gazebo publishes
  `/clock` at its physics rate — hundreds of hertz — so the gap
  between a sample and the capture it is used on is milliseconds, and
  the error is a fraction of that. Far inside the jitter the stamps
  already carry.

  ## Reads are lock-free

  `Timing` is called on every published message, so the offset lives
  in `:atomics` rather than behind a `GenServer.call`. The reference
  goes into `:persistent_term` exactly once, at start — a single
  write, not a per-sample one, because a `:persistent_term` write
  triggers a global scan and `/clock` arrives far too often for that.

  Absent this process — the vehicle, and every test — `offset_ns/0`
  answers `nil` and `Timing` keeps its wall-clock behaviour. Sim time
  is opt-in, and nothing about the real path changes.

  ## Why `init/1` blocks

  It waits for the first `/clock` sample before returning, which holds
  up the rest of the supervision tree for as long as that takes. That
  is deliberate, and it is not about tidiness.

  A single message published before the offset is known carries a
  wall-clock stamp, and on `/tf` that is unrecoverable. `tf2` prunes
  its buffer relative to its **newest** entry, so one transform
  stamped 1.79e9 seconds discards every legitimate simulator-time
  entry that follows it. The buffer ends up holding only the poisoned
  entry, and every point cloud after that is rejected with

      the timestamp on the message is earlier than all the data in
      the transform cache

  It does not recover, because the bad entry is decades in the future
  and never ages out. Measured: the static-transform publisher won its
  race against the first `/clock` sample by *zero milliseconds*, and
  that was enough to make the costmaps ignore stereo for the whole
  run.

  So this is listed first among a vehicle's simulation components, and
  blocking here means no publisher can emit a wall-clock stamp into a
  simulator's graph. If no clock arrives within
  the timeout below, it gives up loudly and lets the bridge run
  on wall clock — degraded, but with a reason in the log rather than a
  boot that never finishes.
  """
  use GenServer

  alias Ros2.RosgraphMsgs.Msg.Clock, as: ClockMessage

  require Logger

  # Gazebo publishes /clock as soon as it is up, so this only ever
  # elapses when the simulator is absent — which is worth reporting
  # rather than hanging on.
  @default_acquire_timeout_ms 10_000

  @persistent_key __MODULE__
  @offset_slot 1
  @tracking_slot 2
  @topic "clock"

  @doc """
  The monotonic-to-ROS-time offset in nanoseconds, or `nil` when this
  bridge is not following a simulator clock.

  `nil` is the answer on a vehicle and in tests, and it is what keeps
  `RosBridge.Timing` on wall clock there.
  """
  @spec offset_ns() :: integer() | nil
  def offset_ns do
    case :persistent_term.get(@persistent_key, nil) do
      nil ->
        nil

      atomics ->
        case :atomics.get(atomics, @tracking_slot) do
          0 -> nil
          _tracking -> :atomics.get(atomics, @offset_slot)
        end
    end
  end

  @doc "Whether a simulator clock has been seen."
  @spec following?() :: boolean()
  def following?, do: offset_ns() != nil

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    timeout_ms = Keyword.get(List.wrap(opts), :acquire_timeout_ms, @default_acquire_timeout_ms)

    atomics = :atomics.new(2, signed: true)
    # Written once. Reads are on the publish path; writes are not.
    :persistent_term.put(@persistent_key, atomics)

    :ok = RosBridge.ZenohClient.subscribe(@topic, ClockMessage)
    Logger.info("#{__MODULE__}: waiting for /#{@topic} before anything publishes a stamp")

    samples = await_first_sample(atomics, timeout_ms)
    {:ok, %{atomics: atomics, samples: samples}}
  end

  # A selective receive rather than a `handle_continue`: the point is
  # that no *other* process gets to publish first, and anything after
  # `init/1` returns is too late. See the moduledoc.
  defp await_first_sample(atomics, timeout_ms) do
    receive do
      {:ros_message, {_key_expr, %ClockMessage{clock: clock}}} ->
        record(atomics, clock)

        Logger.info(
          "#{__MODULE__}: simulator clock acquired at #{clock.sec}.#{clock.nanosec} — " <>
            "stamps will line up with /tf and /odom."
        )

        1
    after
      timeout_ms ->
        Logger.error(
          "#{__MODULE__}: no /#{@topic} within #{timeout_ms} ms. Continuing on wall clock, " <>
            "which against a simulator means every stamp is decades away from /tf and " <>
            "consumers will reject them. Is the simulator running?"
        )

        0
    end
  end

  @impl true
  def handle_info({:ros_message, {_key_expr, %ClockMessage{clock: clock}}}, state) do
    record(state.atomics, clock)
    {:noreply, %{state | samples: state.samples + 1}}
  end

  def handle_info({:ros_message, {key_expr, message}}, state) do
    Logger.warning("#{__MODULE__} unexpected message on #{key_expr}: #{inspect(message)}")

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Sampled as close together as the two reads allow; see the moduledoc
  # on why the residual error does not matter.
  defp record(atomics, clock) do
    monotonic_now = System.monotonic_time(:nanosecond)
    simulator_now = clock.sec * 1_000_000_000 + clock.nanosec

    :atomics.put(atomics, @offset_slot, simulator_now - monotonic_now)
    :atomics.put(atomics, @tracking_slot, 1)
    :ok
  end

  @impl true
  def terminate(_reason, _state) do
    # Stop claiming to follow a clock nobody is reading any more; the
    # next publisher call falls back to wall clock rather than using a
    # frozen offset.
    case :persistent_term.get(@persistent_key, nil) do
      nil -> :ok
      atomics -> :atomics.put(atomics, @tracking_slot, 0)
    end

    :ok
  end
end

defmodule RosBridge.Clock do
  @moduledoc """
  What `use_sim_time` means for this bridge.

  Every publisher stamps its output through `RosBridge.Timing`, which
  projects a driver's capture time onto wall clock. On a vehicle that is
  right. Against a simulator it is not: Gazebo owns the clock, starts
  it at zero, and advances it with physics, so a wall-clock stamp is
  most of two decades away from everything else on the graph.

  Pairing left and right frames only needs them to agree with *each
  other*, but Nav2 needs them to agree with **`/tf`**: its costmap
  message filter drops every point cloud with

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
  up the rest of the supervision tree for as long as that takes.

  A single message published before the offset is known carries a
  wall-clock stamp, and on `/tf` that is unrecoverable. `tf2` prunes
  its buffer relative to its **newest** entry, so one transform
  stamped 1.79e9 seconds discards every legitimate simulator-time
  entry that follows it. The buffer ends up holding only the poisoned
  entry, and every point cloud after that is rejected with

      the timestamp on the message is earlier than all the data in
      the transform cache

  It does not recover, because the bad entry is decades in the future
  and never ages out. The static-transform publisher races the first
  `/clock` sample, so this is not a theoretical window.

  So this is listed first among a vehicle's simulation components, and
  blocking here means no publisher can emit a wall-clock stamp into a
  simulator's graph.

  ## Giving up is permanent, on purpose

  If no clock arrives before the timeout, this stops following
  `/clock` altogether — it unsubscribes, and a sample arriving later
  is ignored.

  That is deliberate and it is the uncomfortable choice. Switching to
  simulator time *later* sounds more helpful and is worse: by then
  wall-clock stamps are already in `tf2`'s buffer, and one of those
  poisons it permanently for the reason above. Mixing the two
  timescales in one run is the failure this module exists to prevent,
  so a run that has started on wall clock finishes on wall clock.
  "Permanent" means for the life of this process: the bridge subtree
  is `:rest_for_one` behind `ZenohClient`, so a client crash restarts
  this too and the wait for `/clock` runs again from scratch.

  Which makes the timeout a real deadline rather than a nicety, and
  it is set accordingly: `docker compose up -d` returns long before
  Gazebo has loaded a world, spawned the robot and started
  `ros_gz_bridge` — the node that bridges `/clock` at all — so a
  short deadline would fire during an ordinary cold boot. Override it
  with `:acquire_timeout_ms` if a slower machine needs longer.
  """
  use GenServer

  alias Ros2.RosgraphMsgs.Msg.Clock, as: ClockMessage

  require Logger

  # Outlasts a simulator cold boot; elapses only when no simulator is coming.
  @default_acquire_timeout_ms 60_000

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

  @impl GenServer
  def init(opts) do
    # Keyword list or map, depending on how the component is listed.
    opts = Map.new(opts || [])
    timeout_ms = Map.get(opts, :acquire_timeout_ms, @default_acquire_timeout_ms)
    # Injected so the lifecycle can be tested without a live
    # ZenohClient — see the note on `terminate/2`.
    subscriber = Map.get(opts, :subscriber, RosBridge.ZenohClient)

    # So `terminate/2` actually runs. Without this a supervisor's
    # ordinary `exit(pid, :shutdown)` skips it entirely, and the
    # tracking flag below would survive this process.
    Process.flag(:trap_exit, true)

    atomics = :atomics.new(2, signed: true)
    # Written once. Reads are on the publish path; writes are not.
    :persistent_term.put(@persistent_key, atomics)

    :ok = subscriber.subscribe(@topic, ClockMessage)
    Logger.info("#{__MODULE__}: waiting for /#{@topic} before anything publishes a stamp")

    state = %{atomics: atomics, samples: 0, subscriber: subscriber, following: false}
    {:ok, await_first_sample(state, timeout_ms)}
  end

  # Selective receive: nothing may publish before `init/1` returns (see the moduledoc).
  defp await_first_sample(state, timeout_ms) do
    receive do
      {:ros_message, {_key_expr, %ClockMessage{clock: clock}}} ->
        record_offset(state.atomics, clock)

        Logger.info(
          "#{__MODULE__}: simulator clock acquired at #{clock.sec}.#{clock.nanosec} — " <>
            "stamps will line up with /tf and /odom."
        )

        %{state | samples: 1, following: true}
    after
      timeout_ms ->
        # Stop listening, so a late sample cannot flip the timescale
        # mid-run. See "Giving up is permanent" in the moduledoc.
        :ok = state.subscriber.unsubscribe(@topic)

        Logger.error(
          "#{__MODULE__}: no /#{@topic} within #{timeout_ms} ms — giving up and staying on " <>
            "wall clock for the rest of this run, because switching timescales later " <>
            "corrupts tf2's buffer for good. Against a simulator that means every stamp " <>
            "is decades from /tf and consumers will reject them. Is the simulator running?"
        )

        %{state | following: false}
    end
  end

  @impl GenServer
  def handle_info(
        {:ros_message, {_key_expr, %ClockMessage{clock: clock}}},
        %{following: true} = state
      ) do
    record_offset(state.atomics, clock)
    {:noreply, %{state | samples: state.samples + 1}}
  end

  # Late sample after giving up: ignored (see the moduledoc).
  def handle_info({:ros_message, {_key_expr, %ClockMessage{}}}, state) do
    {:noreply, state}
  end

  def handle_info({:ros_message, {key_expr, message}}, state) do
    Logger.warning("#{__MODULE__} unexpected message on #{key_expr}: #{inspect(message)}")

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp record_offset(atomics, clock) do
    monotonic_now = System.monotonic_time(:nanosecond)
    simulator_now = clock.sec * 1_000_000_000 + clock.nanosec

    :atomics.put(atomics, @offset_slot, simulator_now - monotonic_now)
    :atomics.put(atomics, @tracking_slot, 1)
    :ok
  end

  @doc """
  Stop claiming to follow a clock nobody is updating any more.

  Without this the tracking flag outlives the process, and every
  publisher goes on projecting through an offset that is frozen at the
  moment this stopped — silently drifting, since the simulator's clock
  keeps moving and nothing is left to notice.

  Reached only because `init/1` sets `:trap_exit`: a `GenServer` does
  **not** get `terminate/2` from a supervisor's ordinary
  `exit(pid, :shutdown)` otherwise.
  """
  @impl GenServer
  def terminate(_reason, _state) do
    case :persistent_term.get(@persistent_key, nil) do
      nil -> :ok
      atomics -> :atomics.put(atomics, @tracking_slot, 0)
    end

    :ok
  end
end

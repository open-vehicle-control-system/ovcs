defmodule RosBridge.InputWatchdog do
  @moduledoc """
  Tells a consumer when its ROS input has gone quiet.

  Both command frames carry a `sequence` the consumer increments once
  per sample, and the VMS zeroes a command whose sequence stops
  changing, so the safety decision is made on the vehicle side from the
  bus alone. This watchdog is the bridge's own view of the same event:
  it zeroes what the bridge emits, so the bus reflects reality rather
  than a retransmitted last value, and it names the cause in the log,
  which the VMS cannot do.

      input stops, bridge alive   -> this, and the VMS via the sequence
      bridge stops, VMS alive     -> the VMS via the sequence

  It has to be longer than the largest legitimate gap between samples.
  For `joy` that is the operator's `joy_linux` `autorepeat_rate`
  period: samples keep arriving even when nothing on the controller
  moves. For a planner publishing a velocity command, it is that
  planner's control period.

  Neither is a constant this module should guess, which is why the
  timeout is a required argument rather than a default living here.

  Deliberately pure: the caller owns its `:timer.send_interval`, calls
  `seen/1` on each sample and `check/1` on each tick. That keeps the
  decision testable without waiting for wall-clock time, and the state
  machine below is the part worth testing — a watchdog that reports
  staleness repeatedly, or that never recovers, is worse than none.

  ## Startup grace

  `:silent` is a diagnosis, so it waits before making one: a gamepad
  pairs after boot, a planner is usually launched by hand, and Zenoh
  reconnects on a backoff. Reporting on the first tick of every normal
  boot would train the operator to ignore the one message that catches
  a topic typo. The grace is separate from `timeout_ms`, which bounds
  the gap *between samples* and is shorter than a Zenoh session takes
  to come up. `stale: true` from creation keeps the vehicle safe in
  the meantime; the grace only governs when to say so.
  """

  # How long to wait before calling a never-received input a mistake
  # rather than a slow start. See `startup_grace_elapsed?/1`.
  @startup_grace_ms 5_000

  @enforce_keys [:timeout_ms, :created_at_ms]
  defstruct [
    :timeout_ms,
    :startup_grace_ms,
    :created_at_ms,
    :last_seen_at_ms,
    stale: true,
    reported: false
  ]

  @type t :: %__MODULE__{
          timeout_ms: pos_integer(),
          startup_grace_ms: pos_integer(),
          created_at_ms: integer(),
          last_seen_at_ms: integer() | nil,
          stale: boolean(),
          reported: boolean()
        }

  @typedoc """
  What `check/1` reports.

  `:silent` and `:stale` both mean nothing is arriving, and they are
  separate because the causes have nothing in common. `:silent` is a
  bring-up mistake -- a topic typo, the wrong `ROS_DOMAIN_ID`, a node
  never launched -- and the only fix is at the keyboard. `:stale` is a
  runtime loss of something that was working. A caller that does not
  care can treat them alike; one that logs should not, because
  "cmd_vel_nav went quiet" sends someone looking for a crash that never
  happened.
  """
  @type transition :: :silent | :stale | :fresh | :unchanged

  @doc """
  A watchdog that starts **stale**.

  Starting stale rather than fresh matters: a consumer that has never
  received an input has no business emitting a command, so it emits
  none from the moment it starts.

  Saying so out loud waits for a startup grace, and reports `:silent`
  rather than `:stale` — the two are different diagnoses. See `check/1`.
  """
  @spec new(pos_integer(), pos_integer()) :: t()
  def new(timeout_ms, startup_grace_ms \\ @startup_grace_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 and
             is_integer(startup_grace_ms) and startup_grace_ms > 0 do
    %__MODULE__{
      timeout_ms: timeout_ms,
      startup_grace_ms: startup_grace_ms,
      created_at_ms: now_ms()
    }
  end

  @doc """
  Record that an input sample just arrived.

  Only records; it does not clear staleness. `check/1` owns every
  transition, so a caller learns about recovery from the same place it
  learns about loss, exactly once, rather than having to notice it
  here and act in two places. The cost is that recovery is reported on
  the next tick instead of immediately — one tick, against a timeout
  measured in hundreds of milliseconds.
  """
  @spec seen(t()) :: t()
  def seen(%__MODULE__{} = watchdog) do
    %{watchdog | last_seen_at_ms: now_ms()}
  end

  @doc """
  Report whether the input has *just* gone quiet or *just* recovered.

  Returns a transition only on the edge, and `{:unchanged, watchdog}`
  otherwise — so a caller can act and log once per outage instead of
  once per tick. At a 10 ms tick that is the difference between one
  line and a hundred a second.

  The `:silent` edge is what `new/1` promises: a fresh watchdog has
  never seen a sample, so the very first `check/1` reports it rather
  than falling silent itself. `reported` is what makes that edge
  exist: without it `{stale: true, expired: true}` is indistinguishable
  from "already announced", and a consumer whose topic nobody publishes
  on would say nothing at all — the one bring-up misconfiguration with
  no diagnostic anywhere, since the CAN emitter goes on sending
  well-formed zeros and the VMS-side watcher therefore sees a healthy
  stream.
  """
  @spec check(t()) :: {transition(), t()}
  def check(%__MODULE__{} = watchdog) do
    announced = fn watchdog, stale -> %{watchdog | stale: stale, reported: true} end

    cond do
      not expired?(watchdog) and (watchdog.stale or not watchdog.reported) ->
        {:fresh, announced.(watchdog, false)}

      expired?(watchdog) and is_nil(watchdog.last_seen_at_ms) and not watchdog.reported and
          startup_grace_elapsed?(watchdog) ->
        {:silent, announced.(watchdog, true)}

      expired?(watchdog) and not watchdog.stale ->
        {:stale, announced.(watchdog, true)}

      true ->
        {:unchanged, watchdog}
    end
  end

  @doc """
  Whether the input is considered stale as of the last `check/1`.

  Reads the recorded state rather than re-measuring, so a caller and
  the transition it was told about cannot disagree.
  """
  @spec stale?(t()) :: boolean()
  def stale?(%__MODULE__{stale: stale}), do: stale

  # `max/2` because a slow input's timeout can exceed the grace; see "Startup grace".
  defp startup_grace_elapsed?(%__MODULE__{} = watchdog) do
    now_ms() - watchdog.created_at_ms > max(watchdog.timeout_ms, watchdog.startup_grace_ms)
  end

  defp expired?(%__MODULE__{last_seen_at_ms: nil}), do: true

  defp expired?(%__MODULE__{last_seen_at_ms: last_seen_at_ms, timeout_ms: timeout_ms}) do
    now_ms() - last_seen_at_ms > timeout_ms
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end

defmodule RosBridge.InputWatchdog do
  @moduledoc """
  Tells a consumer when its ROS input has gone quiet.

  ## Why the bridge needs this at all

  `Cantastic.ReceivedFrameWatcher` covers the CAN side: the VMS
  notices when frames stop arriving, and `ROSControl.Throttle` zeroes
  itself when they do. That handles the bridge dying, the BEAM
  crashing, the CAN link being cut.

  It does **not** handle the input going away while the bridge lives,
  and that is the more likely failure. `Cantastic.Emitter` holds its
  data in state and retransmits on a timer, so once a consumer has
  written a throttle the frames keep leaving at the configured rate
  whether or not anything is still feeding them. A joystick unplugged,
  a `joy` node killed, Zenoh partitioned, a planner crashed — the CAN
  bus looks perfectly healthy and carries a command nobody is issuing
  any more.

  So each consumer watches its own input and zeroes what it emits.
  Two hops, and they cover different things:

      input stops, bridge alive   -> this
      bridge stops, VMS alive     -> Cantastic.ReceivedFrameWatcher

  ## Picking a timeout

  It has to be longer than the largest legitimate gap between samples.
  For `joy` that is knowable: the base station runs `joy_linux` with
  `autorepeat_rate` at 20 Hz by default, so samples arrive every 50 ms
  even when nothing on the controller moves. For a planner publishing
  a velocity command, it is that planner's control period.

  Neither is a constant this module should guess, which is why the
  timeout is a required argument rather than a default living here.

  ## No timers inside

  Deliberately pure: the caller owns its `:timer.send_interval`, calls
  `seen/1` on each sample and `check/1` on each tick. That keeps the
  decision testable without waiting for wall-clock time, and the state
  machine below is the part worth testing — a watchdog that reports
  staleness repeatedly, or that never recovers, is worse than none.
  """

  @enforce_keys [:timeout_ms, :created_at]
  defstruct [:timeout_ms, :created_at, :last_seen, stale: true, reported: false]

  @type t :: %__MODULE__{
          timeout_ms: pos_integer(),
          created_at: integer(),
          last_seen: integer() | nil,
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

  Saying so out loud waits one `timeout_ms`, and reports `:silent`
  rather than `:stale` — the two are different diagnoses. See `check/1`.
  """
  @spec new(pos_integer()) :: t()
  def new(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    %__MODULE__{timeout_ms: timeout_ms, created_at: now()}
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
    %{watchdog | last_seen: now()}
  end

  @doc """
  Report whether the input has *just* gone quiet or *just* recovered.

  Returns a transition only on the edge, and `{:unchanged, watchdog}`
  otherwise — so a caller can act and log once per outage instead of
  once per tick. At a 10 ms tick that is the difference between one
  line and a hundred a second.

  The `:silent` edge is what `new/1` promises: a fresh watchdog has
  never seen a sample, so the very first `check/1` reports it rather
  than falling silent itself. Before `reported` existed, `{stale: true,
  expired: true}` matched the catch-all and a consumer whose topic
  nobody published on said nothing at all — the one bring-up
  misconfiguration with no diagnostic anywhere, since the CAN emitter
  goes on sending well-formed zeros and the VMS-side watcher therefore
  sees a healthy stream.
  """
  @spec check(t()) :: {transition(), t()}
  def check(%__MODULE__{} = watchdog) do
    announced = fn watchdog, stale -> %{watchdog | stale: stale, reported: true} end

    cond do
      not expired?(watchdog) and (watchdog.stale or not watchdog.reported) ->
        {:fresh, announced.(watchdog, false)}

      expired?(watchdog) and is_nil(watchdog.last_seen) and not watchdog.reported and
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

  # `:silent` is a diagnosis, so it waits before making one. A gamepad
  # pairs after boot, Zenoh takes a moment to connect, and a planner is
  # usually launched by hand -- reporting "nothing has published since
  # start" on the first 50 ms tick of every normal boot would train the
  # operator to ignore the one message that catches a topic typo.
  #
  # `stale: true` from creation is what keeps the vehicle safe in the
  # meantime; this only governs when it is worth saying out loud.
  defp startup_grace_elapsed?(%__MODULE__{created_at: created_at, timeout_ms: timeout_ms}) do
    now() - created_at > timeout_ms
  end

  defp expired?(%__MODULE__{last_seen: nil}), do: true

  defp expired?(%__MODULE__{last_seen: last_seen, timeout_ms: timeout_ms}) do
    now() - last_seen > timeout_ms
  end

  defp now, do: System.monotonic_time(:millisecond)
end

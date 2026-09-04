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

  @enforce_keys [:timeout_ms]
  defstruct [:timeout_ms, :last_seen, stale: true]

  @type t :: %__MODULE__{
          timeout_ms: pos_integer(),
          last_seen: integer() | nil,
          stale: boolean()
        }

  @doc """
  A watchdog that starts **stale**.

  Starting stale rather than fresh matters: a consumer that has never
  received an input has no business emitting a command, and the first
  `check/1` should say so rather than waiting for a timeout to elapse
  from a start time that meant nothing.
  """
  @spec new(pos_integer()) :: t()
  def new(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    %__MODULE__{timeout_ms: timeout_ms}
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
  Report whether the input has *just* gone stale or *just* recovered.

  Returns `{:stale, watchdog}` or `{:fresh, watchdog}` only on the
  transition, and `{:unchanged, watchdog}` otherwise — so a caller can
  act and log once per outage instead of once per tick. At a 10 ms tick
  that is the difference between one line and a hundred a second.
  """
  @spec check(t()) :: {:stale | :fresh | :unchanged, t()}
  def check(%__MODULE__{} = watchdog) do
    case {watchdog.stale, expired?(watchdog)} do
      {false, true} -> {:stale, %{watchdog | stale: true}}
      {true, false} -> {:fresh, %{watchdog | stale: false}}
      _unchanged -> {:unchanged, watchdog}
    end
  end

  @doc """
  Whether the input is considered stale as of the last `check/1`.

  Reads the recorded state rather than re-measuring, so a caller and
  the transition it was told about cannot disagree.
  """
  @spec stale?(t()) :: boolean()
  def stale?(%__MODULE__{stale: stale}), do: stale

  defp expired?(%__MODULE__{last_seen: nil}), do: true

  defp expired?(%__MODULE__{last_seen: last_seen, timeout_ms: timeout_ms}) do
    now() - last_seen > timeout_ms
  end

  defp now, do: System.monotonic_time(:millisecond)
end

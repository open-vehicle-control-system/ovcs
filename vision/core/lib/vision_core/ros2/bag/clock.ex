defmodule VisionCore.Ros2.Bag.Clock do
  @moduledoc """
  A recording's clock: the time of its messages' log times, and of the
  stamps of the headers and transforms they carry, from the Erlang
  monotonic times the vision core works in.

    * `:system` - the time the Zenoh exporter stamps with
      (`VisionCore.Timing.export_time_from_monotonic/1`): wall clock, or a
      simulator's when `VisionCore.Ros2.Clock` follows one.
    * `:since_start` - the time since the recording started, for a unit
      whose clock NTP has not set, as in a car without a network. A time
      before the start counts as the start.
    * `:automatic` - `:system` when the clock is synchronized at the start,
      `:since_start` otherwise.

  The clock counts as synchronized as `Ros2Zenoh.Client` decides before it
  publishes, without needing the client to run: the `:ros2_zenoh`
  application's `:clock_synchronized?` check (`NervesTime.synchronized?/0`
  on the vision firmware) answers `true`, or none is configured, as on a
  host; and the BEAM's system time agrees with the OS clock within a second.
  """

  alias Ros2Zenoh.BuiltinInterfaces.Msg.Time
  alias VisionCore.Timing

  @enforce_keys [:mode, :start_monotonic_ns, :synchronized]
  defstruct @enforce_keys

  @type mode :: :system | :since_start
  @type t :: %__MODULE__{mode: mode(), start_monotonic_ns: integer(), synchronized: boolean()}

  @clock_agreement_ms 1_000

  @doc """
  The clock of a recording started at `start_monotonic_ns`, an Erlang
  monotonic time in nanoseconds.

  Options: `:synchronized?`, a function of no argument answering whether the
  clock is synchronized (the check described in the moduledoc).
  """
  @spec new(:system | :since_start | :automatic, integer(), keyword()) :: t()
  def new(mode, start_monotonic_ns, opts \\ [])
      when mode in [:system, :since_start, :automatic] do
    synchronized? = Keyword.get(opts, :synchronized?, &synchronized?/0)
    synchronized = synchronized?.()

    mode =
      case mode do
        :automatic -> if synchronized, do: :system, else: :since_start
        mode -> mode
      end

    %__MODULE__{mode: mode, start_monotonic_ns: start_monotonic_ns, synchronized: synchronized}
  end

  @doc "The time of an Erlang monotonic time, in nanoseconds."
  @spec time_ns(t(), integer()) :: non_neg_integer()
  def time_ns(%__MODULE__{mode: :system}, monotonic_ns),
    do: max(Timing.export_time_from_monotonic(monotonic_ns), 0)

  def time_ns(%__MODULE__{mode: :since_start, start_monotonic_ns: start}, monotonic_ns),
    do: max(monotonic_ns - start, 0)

  @doc "The clock as the ROS 2 builders' `:stamp` option takes it, giving `time_ns/2`'s time."
  @spec stamp(t()) :: VisionCore.Ros2.Stamp.stamp_function()
  def stamp(%__MODULE__{} = clock) do
    fn monotonic_ns ->
      time = time_ns(clock, monotonic_ns)
      %Time{sec: div(time, 1_000_000_000), nanosec: rem(time, 1_000_000_000)}
    end
  end

  @doc "The clock in use and whether the clock was synchronized at the start."
  @spec describe(t()) :: %{clock: String.t(), synchronized: boolean()}
  def describe(%__MODULE__{mode: mode, synchronized: synchronized}),
    do: %{clock: Atom.to_string(mode), synchronized: synchronized}

  defp synchronized? do
    check_passes?(Application.get_env(:ros2_zenoh, :clock_synchronized?)) and
      abs(:os.system_time(:millisecond) - System.system_time(:millisecond)) <=
        @clock_agreement_ms
  end

  defp check_passes?(nil), do: true

  defp check_passes?({module, function, args}) do
    apply(module, function, args) == true
  rescue
    _exception -> false
  catch
    :exit, _reason -> false
  end
end

defmodule VisionCore.Camera.Reopen do
  @moduledoc """
  How a camera driver comes back from a capture program that exits or
  stops delivering: the driver stays up without its Port, and opens it
  again after a wait that grows with each failure in a row,
  `:reopen_delays_ms`, the last one repeated. A frame delivered starts
  the waits over.

  A camera that drops out for a few seconds therefore costs its unit no
  restart, and the processes reading its frames keep their
  subscriptions. Meanwhile the driver answers `running?/1` with `false`,
  which `VisionCore.Status` reports as the camera absent.

  A driver keeps `:port` (`nil` without one), `:failures` and
  `:reopen_delays_ms` in its state, calls `closed/1` when it loses its
  Port, and opens it again on the message `:reopen`.
  """

  @default_delays_ms [1_000, 2_000, 5_000, 10_000, 30_000]

  @doc """
  `opts`' `:reopen_delays_ms` (`[1000, 2000, 5000, 10000, 30000]`), a
  non-empty list of non-negative integers; raises `ArgumentError` on
  another value.
  """
  @spec delays!(keyword()) :: [non_neg_integer(), ...]
  def delays!(opts) do
    delays_ms = Keyword.get(opts, :reopen_delays_ms, @default_delays_ms)

    unless is_list(delays_ms) and delays_ms != [] and
             Enum.all?(delays_ms, &(is_integer(&1) and &1 >= 0)),
           do:
             raise(
               ArgumentError,
               "its :reopen_delays_ms is a non-empty list of non-negative integers, " <>
                 "got #{inspect(delays_ms)}"
             )

    delays_ms
  end

  @doc "The wait before the Port of `state` is opened again, in milliseconds."
  @spec delay_ms(map()) :: non_neg_integer()
  def delay_ms(%{reopen_delays_ms: delays_ms, failures: failures}),
    do: Enum.at(delays_ms, failures, List.last(delays_ms))

  @doc "`state` without its Port, with `:reopen` sent to the calling process after the next wait."
  @spec closed(map()) :: map()
  def closed(state) do
    Process.send_after(self(), :reopen, delay_ms(state))
    %{state | port: nil, failures: state.failures + 1}
  end

  @doc "`state` once its program has delivered a frame: the waits start over."
  @spec delivered(map()) :: map()
  def delivered(state), do: Map.put(state, :failures, 0)

  @doc "Whether the driver `server` has its Port open. `false` when the driver is gone."
  @spec running?(GenServer.server()) :: boolean()
  def running?(server) do
    GenServer.call(server, :running?)
  catch
    :exit, _reason -> false
  end
end

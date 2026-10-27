defmodule OvcsBus.Forwarder do
  @moduledoc """
  Coalesces a node's local `"messages"` traffic into batches for a collector
  on another node.

  A collector starts one forwarder per node of the mesh with
  `Node.spawn_link(node, OvcsBus.Forwarder, :run, [collector, opts])`; the
  forwarder exits when its collector does, whatever the reason. Only the latest
  value of each `{source, name}` signal is kept between ticks, and a value equal
  to the one last sent is dropped, so a chatty signal costs one entry per
  change, not one per publication.

  Batches go out with `:erlang.send/3` and `:nosuspend`: when the distribution
  link is saturated the batch stays pending for the next tick and the skipped
  tick is counted, so no publisher ever waits on the mesh. The running total is
  reported as a `:skipped_ticks` message sourced by this module.

  The collector receives `{:ovcs_bus_batch, node, [{message, timestamp_ms}]}`,
  where the timestamp is the node's `System.os_time(:millisecond)` at receipt.

  Options:

  - `:interval` - milliseconds between batches.
  - `:report_interval` - milliseconds between skipped-tick reports.
  - `:send` - `(collector, message -> term)`, replaceable in tests only.
  """
  use GenServer

  alias OvcsBus.Message

  @topic "messages"

  @doc "Entry point for `Node.spawn_link/4`: subscribes to the local bus and loops."
  @spec run(pid(), keyword()) :: no_return()
  def run(collector, opts \\ []) do
    state = %{
      collector: collector,
      interval: Keyword.get(opts, :interval, 20),
      report_interval: Keyword.get(opts, :report_interval, 1_000),
      send: Keyword.get(opts, :send, &:erlang.send(&1, &2, [:nosuspend])),
      pending: %{},
      sent: %{},
      skipped: 0,
      reported_skipped: 0
    }

    # enter_loop/3 requires the process to look proc_lib-started; Node.spawn_link/4 is not.
    Process.put(:"$ancestors", [collector])
    Process.put(:"$initial_call", {__MODULE__, :run, 2})

    Process.monitor(collector)
    :ok = OvcsBus.subscribe(@topic)
    Process.send_after(self(), :tick, state.interval)
    Process.send_after(self(), :report, state.report_interval)
    :gen_server.enter_loop(__MODULE__, [], state)
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, collector, _reason}, %{collector: collector} = state) do
    {:stop, :normal, state}
  end

  def handle_info(%Message{} = message, state) do
    {:noreply, track(state, message)}
  end

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.interval)
    {:noreply, flush(state)}
  end

  def handle_info(:report, state) do
    Process.send_after(self(), :report, state.report_interval)
    {:noreply, report_skipped(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp track(state, %Message{source: source, name: name, value: value} = message) do
    key = {source, name}

    if not Map.has_key?(state.pending, key) and Map.fetch(state.sent, key) == {:ok, value} do
      state
    else
      put_in(state.pending[key], {message, System.os_time(:millisecond)})
    end
  end

  defp flush(%{pending: pending} = state) when map_size(pending) == 0, do: state

  defp flush(state) do
    batch = state.pending |> Map.values() |> Enum.sort_by(fn {_message, ts} -> ts end)

    case state.send.(state.collector, {:ovcs_bus_batch, node(), batch}) do
      :nosuspend ->
        %{state | skipped: state.skipped + 1}

      _sent ->
        sent =
          for {key, {message, _ts}} <- state.pending, into: state.sent, do: {key, message.value}

        %{state | pending: %{}, sent: sent}
    end
  end

  defp report_skipped(%{skipped: skipped, reported_skipped: skipped} = state), do: state

  defp report_skipped(state) do
    message = %Message{source: __MODULE__, name: :skipped_ticks, value: state.skipped}
    state = track(state, message)
    %{state | reported_skipped: state.skipped}
  end
end

defmodule OvcsBusGateway.Collector do
  @moduledoc """
  Gathers the bus traffic of every node of the mesh on the gateway's node.

  Once distribution is up, the collector starts one `OvcsBus.Forwarder` on each connected
  node and on every node that joins later. A forwarder that exits while its node stays
  connected, for instance when that node's `OvcsBus` restarts, is replaced a second later,
  since no `:nodeup` will follow. A mesh peer (`OvcsBus.Cluster.peers_for/1`) is retried
  even when `OvcsBus.Forwarder` is undefined there, since a peer still booting under
  `mix run` is connected before its code path is set; any other node without the module
  is skipped until its next `:nodeup`. Each batch it receives becomes a list of
  `OvcsBusGateway.Envelope`s, tagged with the role of the publishing node
  (`OvcsBus.Cluster.role/2`), written to `OvcsBusGateway.Cache` and dispatched through
  `OvcsBusGateway.Subscribers`. Forwarders push batches without waiting, so publishers never
  wait on the collector. Each envelope it receives has `stale: false`. A `{message, timestamp}`
  entry, from the forwarder of an older firmware, gets `timestamp` as its change time and
  `nil` as its publish time and staleness, since that forwarder does not refresh; an entry of
  any other shape is skipped.

  Every stale check interval, the collector marks `stale: true` each envelope with
  `stale: false` that it has not received for the stale delay, and dispatches it again, so
  every adapter sees the signal go stale.

  The collector also reports each node's presence the same way: a `connected` signal,
  sourced by this module and tagged with the node's role, set to `true` when it starts a
  forwarder on the node at start or on `:nodeup`, and to `false` on `:nodedown`. Its
  staleness is `nil`.

  Options:

  - `:vehicle` - vehicle module the node roles are derived from.
  - `:forwarder_opts` - keyword list passed to `OvcsBus.Forwarder.run/2`, default `[]`.
  - `:stale_after` - milliseconds without receiving a signal before it is stale, default
    `3_000`.
  - `:stale_check_interval` - milliseconds between stale checks, default `1_000`.
  - `:alive?` - `(-> boolean())` distribution check, replaceable in tests only.
  - `:peers` - `(-> [node()])` the mesh's node names, replaceable in tests only.
  """

  use GenServer
  require Logger

  alias OvcsBusGateway.{Cache, Envelope, Subscribers}

  @retry_interval 1_000
  @stale_after 3_000
  @stale_check_interval 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    send(self(), :start)

    vehicle = Keyword.fetch!(opts, :vehicle)
    stale_check_interval = Keyword.get(opts, :stale_check_interval, @stale_check_interval)
    Process.send_after(self(), :check_stale, stale_check_interval)

    {:ok,
     %{
       vehicle: vehicle,
       peers: Keyword.get(opts, :peers, fn -> OvcsBus.Cluster.peers_for(vehicle) end),
       forwarder_opts: Keyword.get(opts, :forwarder_opts, []),
       alive?: Keyword.get(opts, :alive?, &Node.alive?/0),
       stale_after: Keyword.get(opts, :stale_after, @stale_after),
       stale_check_interval: stale_check_interval,
       forwarders: %{},
       roles: %{}
     }}
  end

  @impl GenServer
  def handle_info(:start, state) do
    if state.alive?.() do
      :ok = :net_kernel.monitor_nodes(true)
      {:noreply, Enum.reduce([node() | Node.list()], state, &start_node/2)}
    else
      Process.send_after(self(), :start, @retry_interval)
      {:noreply, state}
    end
  end

  def handle_info({:nodeup, node}, state), do: {:noreply, start_node(node, state)}

  def handle_info({:nodedown, node}, state) do
    Logger.info("OvcsBusGateway.Collector lost #{node}")
    state = publish_presence(node, false, state)
    forwarders = Map.reject(state.forwarders, fn {_pid, n} -> n == node end)
    {:noreply, %{state | forwarders: forwarders, roles: Map.delete(state.roles, node)}}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    case Map.pop(state.forwarders, pid) do
      {nil, _forwarders} ->
        {:noreply, state}

      {node, forwarders} ->
        cond do
          reason == :noconnection ->
            log_exit(node, reason)

          forwarder_undefined?(reason) and node not in state.peers.() ->
            Logger.info(
              "OvcsBusGateway.Collector: #{node} has no OvcsBus; " <>
                "no forwarder until it reconnects"
            )

          true ->
            log_exit(node, reason)
            Process.send_after(self(), {:respawn, node}, @retry_interval)
        end

        {:noreply, %{state | forwarders: forwarders}}
    end
  end

  def handle_info({:respawn, node}, state) do
    if connected?(node),
      do: {:noreply, start_forwarder(node, state)},
      else: {:noreply, state}
  end

  def handle_info({:ovcs_bus_batch, node, entries}, state) when is_list(entries) do
    {role, state} = role(node, state)

    entries
    |> Enum.flat_map(&envelopes(&1, role, node))
    |> deliver()

    {:noreply, state}
  end

  def handle_info({:ovcs_bus_batch, node, batch}, state) do
    Logger.debug(
      "OvcsBusGateway.Collector skipped an unknown batch from #{node}: #{inspect(batch)}"
    )

    {:noreply, state}
  end

  def handle_info(:check_stale, state) do
    Process.send_after(self(), :check_stale, state.stale_check_interval)

    case Cache.mark_stale(System.monotonic_time(:millisecond) - state.stale_after) do
      [] -> :ok
      stale -> Subscribers.dispatch(stale)
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp envelopes({%OvcsBus.Message{} = message, changed_at, published_at}, role, _node),
    do: [%{Envelope.new(role, message, changed_at, published_at) | stale: false}]

  # The entry shape of a forwarder that does not track publish times.
  defp envelopes({%OvcsBus.Message{} = message, timestamp}, role, _node),
    do: [Envelope.new(role, message, timestamp, nil)]

  defp envelopes(entry, _role, node) do
    Logger.debug(
      "OvcsBusGateway.Collector skipped an unknown batch entry from #{node}: #{inspect(entry)}"
    )

    []
  end

  defp deliver(envelopes) do
    Cache.put_all(envelopes)
    Subscribers.dispatch(envelopes)
  end

  defp start_node(node, state) do
    if node in Map.values(state.forwarders),
      do: state,
      else: publish_presence(node, true, start_forwarder(node, state))
  end

  defp publish_presence(node, connected?, state) do
    {role, state} = role(node, state)
    message = %OvcsBus.Message{source: __MODULE__, name: :connected, value: connected?}
    now = System.os_time(:millisecond)
    deliver([Envelope.new(role, message, now, now)])
    state
  end

  defp start_forwarder(node, state) do
    if node in Map.values(state.forwarders) do
      state
    else
      Logger.info("OvcsBusGateway.Collector starting a forwarder on #{node}")
      pid = Node.spawn_link(node, OvcsBus.Forwarder, :run, [self(), state.forwarder_opts])
      put_in(state.forwarders[pid], node)
    end
  end

  defp connected?(node), do: node == node() or node in Node.list()

  defp forwarder_undefined?({:undef, [{OvcsBus.Forwarder, :run, [_, _], _} | _]}), do: true
  defp forwarder_undefined?(_reason), do: false

  # What a peer still booting returns: its code path or its `OvcsBus` is not up yet.
  defp booting?(reason),
    do: forwarder_undefined?(reason) or bus_not_started?(reason)

  defp bus_not_started?({%ArgumentError{message: "unknown registry: OvcsBus"}, _stacktrace}),
    do: true

  defp bus_not_started?(_reason), do: false

  defp log_exit(_node, :normal), do: :ok

  defp log_exit(node, :noconnection),
    do: Logger.debug("OvcsBusGateway.Collector forwarder on #{node} lost its connection")

  defp log_exit(node, reason) do
    level = if booting?(reason), do: :info, else: :warning
    Logger.log(level, "OvcsBusGateway.Collector forwarder on #{node} exited: #{inspect(reason)}")
  end

  defp role(node, state) do
    case state.roles do
      %{^node => role} ->
        {role, state}

      roles ->
        role = OvcsBus.Cluster.role(node, state.vehicle)
        {role, %{state | roles: Map.put(roles, node, role)}}
    end
  end
end

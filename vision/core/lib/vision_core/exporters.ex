defmodule VisionCore.Exporters do
  @moduledoc """
  Runs the vision unit's exporters (`VisionCore.Exporter`), each under a
  `VisionCore.Exporter.Supervisor` with a restart budget of its own,
  `:one_for_one`: an exporter that keeps crashing stops alone, for good,
  and is logged as stopped. Its child stays in the list, without a
  process.

  `VisionCore.Application` starts it last in `VisionCore.Supervisor`,
  after the components, `VisionCore.Status` and `VisionCore.Preview`:
  under `:rest_for_one`, a restart of the exporters restarts nothing
  else.

  Each exporter's child id is the `:id` in its options, its module
  without one. An exporter whose id is already taken is not started,
  with an error logged: two of one module need an `:id` each. The last
  child, a worker, watches the exporters' supervisors to log those that
  stop.

  ## Options

    * `:config` — the active `VisionCore.Config` (required), in which the
      exporters' outputs resolve.
    * `:exporters` (`from_config/1` of `:config`) — the exporters to run,
      each `{module, options}`. A `:name` in the options registers the
      exporter's runner under it.
    * `:jpeg_codec` (`VisionCore.Jpeg`) — the `VisionCore.Jpeg` instance
      the exporters encode on, put in each one's options as
      `:jpeg_codec` unless it has its own. `VisionCore.Application`
      gives `VisionCore.Jpeg.Export`, apart from the pipeline's.
  """
  use Supervisor
  require Logger

  alias VisionCore.Exporter
  alias VisionCore.Exporters.Watch

  @doc "Starts the exporters; see the module doc for `opts`."
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The exporters `config` runs, each `{module, options}`: none, whatever `config` holds."
  @spec from_config(VisionCore.Config.t()) :: [{module(), keyword()}]
  def from_config(%VisionCore.Config{}), do: []

  @impl Supervisor
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    jpeg_codec = Keyword.get(opts, :jpeg_codec, VisionCore.Jpeg)

    exporters =
      opts
      |> Keyword.get_lazy(:exporters, fn -> from_config(config) end)
      |> Enum.map(fn {exporter, options} ->
        Exporter.Supervisor.child_spec(
          exporter: exporter,
          options: Keyword.put_new(options, :jpeg_codec, jpeg_codec),
          config: config
        )
      end)
      |> Enum.reduce({[], MapSet.new([Watch])}, &keep_first_of_id/2)
      |> elem(0)
      |> Enum.reverse()

    Supervisor.init(exporters ++ [{Watch, self()}], strategy: :one_for_one)
  end

  # A second child under one id would fail this supervisor's start, and with it the vision core's.
  defp keep_first_of_id(%{id: id, start: {_module, _function, [opts]}} = child, {kept, ids}) do
    if MapSet.member?(ids, id) do
      Logger.error(
        "#{inspect(opts[:exporter])} not started: an exporter already runs under the id " <>
          "#{inspect(id)}; give each its own :id"
      )

      {kept, ids}
    else
      {[child | kept], MapSet.put(ids, id)}
    end
  end
end

defmodule VisionCore.Exporters.Watch do
  @moduledoc false
  # Started after the exporters, so an orderly shutdown stops it first and it sees none stop.
  use GenServer
  require Logger

  def start_link(exporters), do: GenServer.start_link(__MODULE__, exporters)

  @impl GenServer
  def init(exporters), do: {:ok, %{exporters: exporters, watched: %{}}, {:continue, :watch}}

  @impl GenServer
  def handle_continue(:watch, state), do: {:noreply, watch(state)}

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    {{id, _pid}, watched} = Map.pop(state.watched, monitor)
    if reason == :shutdown, do: log_stopped(id)
    {:noreply, watch(%{state | watched: watched})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp log_stopped(id) do
    Logger.error("#{inspect(id)} stopped: it kept failing; the vision unit runs on without it")
  end

  # Monitors every exporter supervisor running and not yet watched.
  defp watch(state) do
    watched_pids = Map.new(state.watched, fn {_monitor, {_id, pid}} -> {pid, true} end)

    watched =
      for {id, pid, :supervisor, _modules} <- Supervisor.which_children(state.exporters),
          is_pid(pid),
          not is_map_key(watched_pids, pid),
          into: state.watched,
          do: {Process.monitor(pid), {id, pid}}

    %{state | watched: watched}
  end
end

defmodule VisionCore.Exporters do
  @moduledoc """
  Runs the vision unit's exporters (`VisionCore.Exporter`), the
  `:exporters` of its `VisionCore.Config`, each under a
  `VisionCore.Exporter.Supervisor` with a restart budget of its own,
  `:one_for_one`: an exporter that keeps crashing stops alone, for good,
  and is logged as stopped. Its child stays in the list, without a
  process, as does an exporter that was not started.

  `VisionCore.Application` starts it after the components and before
  `VisionCore.Status`, which reports the exporters' statuses
  (`list/1`), and `VisionCore.Preview`: under `:rest_for_one`, their
  restarts do not restart the exporters.

  Each exporter's child id is its id (`VisionCore.Exporter.identity/2`).
  An exporter whose id is already taken is not started, with an error
  logged: two of one module need an `:id` each. So is an entry that is
  neither `{module, options}` nor a module, which runs as
  `{module, []}`. The last child, a worker, watches the exporters'
  supervisors to log those that stop because they kept failing, not
  those stopped on purpose. Why an exporter does not run, refused or
  failed at start or stopped for failing, is kept for `list/1` while
  this supervisor runs.

  ## Options

    * `:config` — the active `VisionCore.Config` (required), in which the
      exporters' outputs resolve, and which each exporter is given in
      its options as `:config`.
    * `:exporters` (the `:exporters` of `:config`) — the exporters to run,
      each `{module, options}` or a module. A `:name` in the options
      registers the exporter's runner under it.
    * `:jpeg_codec` (`VisionCore.Jpeg`) — the `VisionCore.Jpeg` instance
      the exporters encode on, put in each one's options as
      `:jpeg_codec` unless it has its own. `VisionCore.Application`
      gives `VisionCore.Jpeg.Export`, apart from the pipeline's.
  """
  use Supervisor
  require Logger

  alias VisionCore.Exporter
  alias VisionCore.Exporter.Runner
  alias VisionCore.Exporters.Watch

  @default_status_timeout_ms 200
  # Why each exporter that does not run stopped; it goes with this supervisor.
  @stops VisionCore.Exporters.Stops

  @typedoc "One output an exporter reads, with the most values it is handed a second, if bounded."
  @type listed_output :: %{output: Exporter.output(), max_hz: number() | nil}

  @typedoc "An exporter as `list/1` lists it."
  @type entry :: %{
          id: String.t(),
          name: String.t(),
          module: module(),
          status: Exporter.status(),
          outputs: [listed_output()],
          actions: [Exporter.action()]
        }

  @doc "Starts the exporters; see the module doc for `opts`."
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The exporters the unit runs, in the order of its configuration: each
  one's id, as text, and name (`VisionCore.Exporter.identity/2`), its
  module, its status (`VisionCore.Exporter.Runner.status/2`), the
  outputs its runner reads, those the configuration produces
  (`VisionCore.Exporter.output_specs/2`), and its actions
  (`VisionCore.Exporter.actions/2`). An exporter that is not
  running is off, saying why: not started, with the reason it was
  refused or failed to start, stopped because it kept failing, or not
  running. The statuses are asked all at once, and one that does not
  come within `timeout_ms` is a warning, so that a stuck exporter holds
  up neither the others nor the caller. `[]` while the exporters do not
  run.
  """
  @spec list(timeout()) :: [entry()]
  def list(timeout_ms \\ @default_status_timeout_ms) do
    listed =
      for {id, supervisor, :supervisor, _modules} <- children(__MODULE__),
          {:ok, %{start: {_module, _function, [opts]}}} <- [exporter_spec(id)],
          do: {id, opts, supervisor}

    listed = Enum.reverse(listed)
    statuses = statuses(listed, timeout_ms)

    Enum.zip_with(listed, statuses, fn {_id, opts, _supervisor}, status -> entry(opts, status) end)
  end

  @doc """
  Runs the action named `name`, with `params`, of the exporter whose id
  `list/1` lists as `id`, waiting up to `timeout` for its result
  (`VisionCore.Exporter.Runner.action/4`): `{:error, :not_found}` for an
  id no exporter has, `{:error, :not_running}` when the exporter does
  not run, or stops before answering, and `{:error, {:timeout, message}}`
  when it does not answer within `timeout`.
  """
  @spec action(String.t(), String.t(), map(), timeout()) ::
          Exporter.action_result() | {:error, :not_found | :not_running | :unknown_action}
  def action(id, name, params, timeout) do
    case List.keyfind(exporter_supervisors(), id, 0) do
      nil -> {:error, :not_found}
      {^id, supervisor} -> run_action(supervisor, name, params, timeout)
    end
  end

  defp exporter_supervisors do
    for {id, supervisor, :supervisor, _modules} <- children(__MODULE__),
        do: {id_text(id), supervisor}
  end

  defp run_action(supervisor, name, params, timeout) do
    case runner(supervisor) do
      nil -> {:error, :not_running}
      runner -> Runner.action(runner, name, params, timeout)
    end
  catch
    :exit, {:timeout, _call} ->
      {:error, {:timeout, "The exporter did not answer within #{timeout} ms"}}

    :exit, _reason ->
      {:error, :not_running}
  end

  @doc false
  @spec stopped(term(), String.t()) :: :ok
  def stopped(id, why) do
    :ets.insert(@stops, {id, why})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp stop_reason(id) do
    case :ets.lookup(@stops, id) do
      [{^id, why}] -> why
      [] -> "Not running"
    end
  rescue
    ArgumentError -> "Not running"
  end

  defp children(supervisor) do
    Supervisor.which_children(supervisor)
  catch
    :exit, _reason -> []
  end

  defp exporter_spec(id) do
    :supervisor.get_childspec(__MODULE__, id)
  catch
    :exit, _reason -> {:error, :not_running}
  end

  defp entry(opts, status) do
    exporter = Keyword.fetch!(opts, :exporter)
    options = Keyword.get(opts, :options, [])
    %{id: id, name: name} = Exporter.identity(exporter, options)
    config = Keyword.get_lazy(opts, :config, &VisionCore.Application.active_config/0)

    %{
      id: id_text(id),
      name: name,
      module: exporter,
      status: status,
      outputs: listed_outputs(exporter, options, config),
      actions: Exporter.actions(exporter, options)
    }
  end

  defp id_text(id) when is_binary(id), do: id

  defp id_text(id) when is_atom(id) do
    text = Atom.to_string(id)
    if String.starts_with?(text, "Elixir."), do: inspect(id), else: text
  end

  defp id_text(id), do: inspect(id)

  # As the runner reads them: those the configuration produces.
  defp listed_outputs(exporter, options, config) do
    case Exporter.output_specs(exporter, options) do
      {:ok, specs} ->
        for {output, max_hz} <- specs,
            Exporter.output_key(output, config) != nil,
            do: %{output: output, max_hz: max_hz}

      {:error, _reason} ->
        []
    end
  end

  # An exporter's status is its runner's, asked of each running one in a task of its own.
  defp statuses(listed, timeout_ms) do
    asked =
      Enum.map(listed, fn
        {id, _opts, :undefined} -> {:off, stop_reason(id)}
        {_id, _opts, supervisor} -> Task.async(fn -> runner_status(supervisor, timeout_ms) end)
      end)

    replies =
      asked
      |> Enum.filter(&is_struct(&1, Task))
      |> Task.yield_many(timeout_ms)
      |> Map.new(fn {task, reply} -> {task.ref, reply || Task.shutdown(task, :brutal_kill)} end)

    Enum.map(asked, fn
      %Task{ref: ref} ->
        case replies[ref] do
          {:ok, status} -> status
          _late -> {:warning, "Not answering"}
        end

      off ->
        off
    end)
  end

  defp runner_status(supervisor, timeout_ms) do
    case runner(supervisor) do
      nil -> {:off, "Not running"}
      runner -> Runner.status(runner, timeout_ms)
    end
  end

  defp runner(:undefined), do: nil

  defp runner(supervisor) do
    case List.keyfind(children(supervisor), Runner, 0) do
      {Runner, runner, :worker, _modules} when is_pid(runner) -> runner
      _not_running -> nil
    end
  end

  @impl Supervisor
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    jpeg_codec = Keyword.get(opts, :jpeg_codec, VisionCore.Jpeg)
    :ets.new(@stops, [:named_table, :public])

    exporters =
      opts
      |> Keyword.get(:exporters, config.exporters)
      |> Enum.flat_map(&exporter_entry/1)
      |> Enum.map(fn {exporter, options} ->
        options =
          options |> Keyword.put_new(:jpeg_codec, jpeg_codec) |> Keyword.put_new(:config, config)

        Exporter.Supervisor.child_spec(exporter: exporter, options: options, config: config)
      end)
      |> Enum.reduce({[], MapSet.new([Watch])}, &keep_first_of_id/2)
      |> elem(0)
      |> Enum.reverse()

    Supervisor.init(exporters ++ [{Watch, self()}], strategy: :one_for_one)
  end

  defp exporter_entry({exporter, options}) when is_atom(exporter) and is_list(options) do
    if Keyword.keyword?(options),
      do: [{exporter, options}],
      else: not_an_exporter({exporter, options})
  end

  defp exporter_entry(exporter) when is_atom(exporter), do: [{exporter, []}]
  defp exporter_entry(entry), do: not_an_exporter(entry)

  defp not_an_exporter(entry) do
    Logger.error(
      "#{inspect(entry)} not started: not an exporter, which :exporters lists as " <>
        "{module, options} or a module"
    )

    []
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
  # An exporter supervisor that gives up and one stopped on purpose both exit :shutdown: what
  # tells them apart is a child of the exporter's that exited abnormally and was not seen again.
  use GenServer
  require Logger

  def start_link(exporters), do: GenServer.start_link(__MODULE__, exporters)

  @impl GenServer
  def init(exporters),
    do: {:ok, %{exporters: exporters, watched: %{}, failing: %{}}, {:continue, :watch}}

  @impl GenServer
  def handle_continue(:watch, state), do: {:noreply, watch(state)}

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    {watched, state} = pop_in(state, [:watched, monitor])
    {:noreply, state |> stopped(watched, reason) |> watch()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp stopped(state, {id, :exporter, _pid}, reason) do
    if reason == :shutdown and failing?(state, id), do: gave_up(id)
    %{state | failing: Map.delete(state.failing, id)}
  end

  defp stopped(state, {id, child, _pid}, reason) do
    if crash?(reason),
      do: update_in(state, [:failing, Access.key(id, MapSet.new())], &MapSet.put(&1, child)),
      else: state
  end

  defp failing?(state, id), do: MapSet.size(Map.get(state.failing, id, MapSet.new())) > 0

  defp crash?({:shutdown, _reason}), do: false
  defp crash?(reason), do: reason not in [:normal, :shutdown, :noproc]

  defp gave_up(id) do
    Logger.error("#{inspect(id)} stopped: it kept failing; the vision unit runs on without it")
    VisionCore.Exporters.stopped(id, "Stopped: it kept failing")
  end

  # Monitors each exporter supervisor and child not yet watched; a child seen running is not failing.
  defp watch(state) do
    watched_pids = MapSet.new(state.watched, fn {_monitor, {_id, _what, pid}} -> pid end)

    for {id, pid, :supervisor, _modules} <- which_children(state.exporters),
        is_pid(pid),
        reduce: state do
      state ->
        for {child, child_pid, _type, _modules} <- which_children(pid),
            is_pid(child_pid),
            reduce: monitor(state, {id, :exporter, pid}, watched_pids) do
          state ->
            state
            |> monitor({id, child, child_pid}, watched_pids)
            |> running(id, child, child_pid)
        end
    end
  end

  defp monitor(state, {_id, _what, pid} = watched, watched_pids) do
    if MapSet.member?(watched_pids, pid),
      do: state,
      else: put_in(state, [:watched, Process.monitor(pid)], watched)
  end

  defp running(state, id, child, pid) do
    if Process.alive?(pid),
      do: update_in(state, [:failing, Access.key(id, MapSet.new())], &MapSet.delete(&1, child)),
      else: state
  end

  # A supervisor that stops while asked has no children to watch.
  defp which_children(supervisor) do
    Supervisor.which_children(supervisor)
  catch
    :exit, _reason -> []
  end
end

defmodule VisionCore.Exporter.Supervisor do
  @moduledoc """
  One exporter under a restart budget of its own: the helper processes
  its `c:VisionCore.Exporter.children/1` names, then the
  `VisionCore.Exporter.Runner` running it. `:rest_for_one`, so the
  runner restarts with a helper it may hold state about.

  `VisionCore.Exporters` starts it as a `:transient` child: an exporter
  that keeps crashing exhausts this budget, its supervisor shuts down and
  stays down, and the cameras, the pipelines and the other exporters run
  on. An exporter that cannot start, because its outputs are invalid or
  a helper fails to start, is left down the same way, with an error
  logged; an exporter whose `c:VisionCore.Exporter.init/1` fails is not
  one of them, its runner trying it again.

  Before anything starts, the exporter's `c:VisionCore.Exporter.check/1`,
  when it has one, is asked whether it can run: when it cannot, or
  raises, the exporter is left down the same way, with its reason logged.
  Why an exporter is left down is kept for `VisionCore.Exporters.list/1`.

  Its options are the runner's (`VisionCore.Exporter.Runner`); its child
  id is the exporter's id (`VisionCore.Exporter.identity/2`).
  """
  use Supervisor
  require Logger

  alias VisionCore.Exporter
  alias VisionCore.Exporter.Runner

  @max_restarts 10
  @max_seconds 60

  @doc false
  def child_spec(opts) do
    exporter = Keyword.fetch!(opts, :exporter)

    %{
      id: Exporter.identity(exporter, Keyword.get(opts, :options, [])).id,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :transient
    }
  end

  @doc """
  Starts the exporter `opts` names; `:ignore` when its check refuses it or
  it fails to start, so the vision core starts without it.
  """
  def start_link(opts) do
    exporter = Keyword.fetch!(opts, :exporter)
    options = Keyword.get(opts, :options, [])

    with :ok <- check(exporter, options),
         {:ok, _supervisor} = started <- Supervisor.start_link(__MODULE__, opts) do
      started
    else
      {:refused, reason} ->
        Logger.error("#{inspect(exporter)} not started: #{reason}")
        not_started(exporter, options, reason)

      {:error, reason} ->
        Logger.error("#{inspect(exporter)} failed to start, not exporting: " <> inspect(reason))
        not_started(exporter, options, start_failure_text(reason))
    end
  end

  defp not_started(exporter, options, reason) do
    VisionCore.Exporters.stopped(
      Exporter.identity(exporter, options).id,
      "Not started: " <> reason
    )

    :ignore
  end

  defp start_failure_text({:shutdown, {:failed_to_start_child, child, reason}}),
    do: "#{inspect(child)} failed to start: #{inspect(reason)}"

  defp start_failure_text(reason), do: inspect(reason)

  defp check(exporter, options) do
    with true <- Code.ensure_loaded?(exporter) and function_exported?(exporter, :check, 1),
         {:error, reason} <- exporter.check(options) do
      {:refused, if(is_binary(reason), do: reason, else: inspect(reason))}
    else
      _can_run -> :ok
    end
  catch
    :error, reason -> {:refused, Exception.message(Exception.normalize(:error, reason))}
    kind, reason -> {:refused, "#{kind}: #{inspect(reason)}"}
  end

  @impl Supervisor
  def init(opts) do
    exporter = Code.ensure_loaded!(Keyword.fetch!(opts, :exporter))

    helpers =
      if function_exported?(exporter, :children, 1),
        do: exporter.children(Keyword.get(opts, :options, [])),
        else: []

    Supervisor.init(helpers ++ [{Runner, opts}],
      strategy: :rest_for_one,
      max_restarts: @max_restarts,
      max_seconds: @max_seconds
    )
  end
end

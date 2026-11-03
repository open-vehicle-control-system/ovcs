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

  Its options are the runner's (`VisionCore.Exporter.Runner`); its child
  id is the exporter's `:id` option, or without one the exporter's
  module.
  """
  use Supervisor
  require Logger

  alias VisionCore.Exporter.Runner

  @max_restarts 10
  @max_seconds 60

  @doc false
  def child_spec(opts) do
    exporter = Keyword.fetch!(opts, :exporter)

    %{
      id: opts |> Keyword.get(:options, []) |> Keyword.get(:id, exporter),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :transient
    }
  end

  @doc """
  Starts the exporter `opts` names; `:ignore` when it fails to start, so
  the vision core starts without it.
  """
  def start_link(opts) do
    case Supervisor.start_link(__MODULE__, opts) do
      {:error, reason} ->
        Logger.error(
          "#{inspect(Keyword.fetch!(opts, :exporter))} failed to start, not exporting: " <>
            inspect(reason)
        )

        :ignore

      started ->
        started
    end
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

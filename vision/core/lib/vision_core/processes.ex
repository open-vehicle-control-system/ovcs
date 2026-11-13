defmodule VisionCore.Processes do
  @moduledoc """
  The registry of the processes that serve the unit's pipelines: each
  is registered under its module and its pipeline's name,
  `{module, name}`, so a pipeline's name makes no process name of its
  own. `VisionCore.Pipelines.server/2` gives the name to start one
  under and to call it by.

  `VisionCore.Application` starts the registry before the components.
  """

  @doc "Starts the registry."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(_opts \\ []), do: Registry.start_link(keys: :unique, name: __MODULE__)

  @doc false
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}

  @doc "The name `module`'s process of the pipeline `name` is registered under."
  @spec via(module(), atom()) :: {:via, Registry, {__MODULE__, {module(), atom()}}}
  def via(module, name), do: {:via, Registry, {__MODULE__, {module, name}}}
end

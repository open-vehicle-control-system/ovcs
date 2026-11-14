defmodule VisionCore.Consumers do
  @moduledoc """
  Supervises what reads the components' outputs: the exporters and
  their JPEG codec, the calibration recorder and session, and the
  dashboard's sources, `VisionCore.Status`, `VisionCore.Preview` and
  `VisionCore.Video`.

  They start in that order and the strategy is `:rest_for_one`: a
  restart of the codec restarts its users, and a restart of the
  dashboard's sources leaves the exporters running.

  The supervisor has its own restart budget, and
  `VisionCore.Application` starts it as a `:transient` child of
  `VisionCore.Supervisor`: consumers that keep crashing exhaust this
  budget and stop together, and the cameras and pipelines run on.
  `VisionCore.Reviver` starts them again later.
  """

  @max_restarts 10
  @max_seconds 60

  @doc false
  def child_spec(children) do
    %{
      id: __MODULE__,
      type: :supervisor,
      restart: :transient,
      start: {__MODULE__, :start_link, [children]}
    }
  end

  @doc "Starts the supervisor with `children`, the consumers' child specs in start order."
  @spec start_link([Supervisor.child_spec() | {module(), term()} | module()]) ::
          Supervisor.on_start()
  def start_link(children) do
    Supervisor.start_link(children,
      strategy: :rest_for_one,
      max_restarts: @max_restarts,
      max_seconds: @max_seconds,
      name: __MODULE__
    )
  end
end

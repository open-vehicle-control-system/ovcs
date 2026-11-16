defmodule VisionCore.Hailo.Supervisor do
  @moduledoc """
  Runs `VisionCore.Hailo` within a restart budget of its own, so a Port
  process crashing in a loop stops here: the vision core's supervisor,
  `:rest_for_one`, restarts what follows a child that exits, the stereo
  unit among them, and a Hailo fault must not take the depth down. The
  units on the accelerator restart with `VisionCore.Hailo`
  (`VisionCore.Inference.Watch`); `VisionCore.Reviver` starts this
  supervisor again once it gives up, as it does a unit.

  Its options are `VisionCore.Hailo`'s.
  """
  use Supervisor

  @max_restarts 10
  @max_seconds 60

  @doc """
  Starts it; see `VisionCore.Hailo` for `opts`. `:ignore` when it fails
  to start, as for a model it is not given, so the vision core starts
  without it, its units left down.
  """
  def start_link(opts),
    do: VisionCore.Unit.start_contained(__MODULE__, opts, [name: __MODULE__], "Hailo-8")

  @impl Supervisor
  def init(opts),
    do:
      Supervisor.init([{VisionCore.Hailo, opts}],
        strategy: :one_for_one,
        max_restarts: @max_restarts,
        max_seconds: @max_seconds
      )
end

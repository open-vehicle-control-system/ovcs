defmodule VisionApiWeb.BoardJSON do
  @moduledoc """
  `OvcsVehicle.BoardStatus` as a `boards` singleton: `interfaces`, each a
  `name` with its `addresses`, `cpuPercent`, the CPU's busy share, and
  `loadAverage`, the 1, 5 and 15 minute load averages, `nil` where Linux
  does not report them, the clock's UTC `time` and `clockSynchronized`,
  `nil` on a host.
  """
  alias OvcsVehicle.BoardStatus
  alias VisionApiWeb.JsonApi

  @doc "The `current` board."
  @spec show(%{board: BoardStatus.t()}) :: map()
  def show(%{board: %BoardStatus{} = board}) do
    %{
      data:
        JsonApi.resource("boards", "current", %{
          interfaces: board.interfaces,
          cpuPercent: board.cpu_percent,
          loadAverage: board.load_average,
          time: DateTime.to_iso8601(board.time),
          clockSynchronized: board.synchronized
        })
    }
  end
end

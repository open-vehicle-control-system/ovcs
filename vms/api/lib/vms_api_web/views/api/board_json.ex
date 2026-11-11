defmodule VmsApiWeb.Api.BoardJSON do
  @moduledoc """
  `OvcsVehicle.BoardStatus` as the `board` singleton: `interfaces`, each a
  `name` with its `addresses`, `cpuPercent`, the CPU's busy share, and
  `loadAverage`, the 1, 5 and 15 minute load averages, `nil` where Linux
  does not report them, the clock's UTC `time` and `clockSynchronized`,
  `nil` on a host.
  """
  use VmsApiWeb, :view

  def render("show.json", %{board: board}) do
    %{
      data: %{
        type: "board",
        id: "current",
        attributes: %{
          interfaces: board.interfaces,
          cpuPercent: board.cpu_percent,
          loadAverage: board.load_average,
          time: DateTime.to_iso8601(board.time),
          clockSynchronized: board.synchronized
        }
      }
    }
  end
end

defmodule VmsApiWeb.Api.BoardJSON do
  @moduledoc """
  `OvcsVehicle.BoardStatus` as the `board` singleton: `interfaces`, each a
  `name` with its `addresses`, the clock's UTC `time` and
  `clockSynchronized`, `nil` on a host.
  """
  use VmsApiWeb, :view

  def render("show.json", %{board: board}) do
    %{
      data: %{
        type: "board",
        id: "current",
        attributes: %{
          interfaces: board.interfaces,
          time: DateTime.to_iso8601(board.time),
          clockSynchronized: board.synchronized
        }
      }
    }
  end
end

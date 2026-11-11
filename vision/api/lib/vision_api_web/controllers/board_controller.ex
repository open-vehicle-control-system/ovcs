defmodule VisionApiWeb.BoardController do
  @moduledoc """
  The board the unit runs on, read-only: a `boards` singleton with its
  interfaces' addresses and its clock (`OvcsVehicle.BoardStatus`).
  """
  use VisionApiWeb, :controller

  def show(conn, _params), do: render(conn, :show, board: OvcsVehicle.BoardStatus.current())
end

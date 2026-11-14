defmodule VisionApiWeb.BoardController do
  @moduledoc """
  The board the unit runs on, read-only: the `boards` singleton every API
  serves, with its interfaces' addresses, its load and its clock
  (`OvcsVehicle.BoardStatus.document/1`).
  """
  use VisionApiWeb, :controller

  alias OvcsVehicle.BoardStatus

  def show(conn, _params), do: json(conn, BoardStatus.document(BoardStatus.current()))
end

defmodule VmsApiWeb.Api.BoardController do
  @moduledoc """
  The board the VMS runs on, read-only: its interfaces' addresses and its
  clock (`OvcsVehicle.BoardStatus`).
  """
  use VmsApiWeb, :controller

  def show(conn, _params) do
    conn
    |> put_status(:ok)
    |> render("show.json", %{board: OvcsVehicle.BoardStatus.current()})
  end
end

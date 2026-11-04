defmodule VmsApiWeb.Api.FirmwareController do
  @moduledoc """
  The firmware the VMS runs, read-only: its commit, target, Nerves system
  and vehicle (`OvcsVehicle.FirmwareInfo`).
  """
  use VmsApiWeb, :controller

  def show(conn, _params) do
    conn
    |> put_status(:ok)
    |> render("show.json", %{firmware: OvcsVehicle.FirmwareInfo.current()})
  end
end

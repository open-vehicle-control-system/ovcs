defmodule VisionApiWeb.FirmwareController do
  @moduledoc """
  The firmware the unit runs, read-only: a `firmwares` singleton with the
  commit it is built from, its target, its Nerves system and its vehicle
  (`OvcsVehicle.FirmwareInfo`).
  """
  use VisionApiWeb, :controller

  def show(conn, _params), do: render(conn, :show, firmware: OvcsVehicle.FirmwareInfo.current())
end

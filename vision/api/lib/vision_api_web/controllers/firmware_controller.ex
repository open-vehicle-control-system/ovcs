defmodule VisionApiWeb.FirmwareController do
  @moduledoc """
  The firmware the unit runs, read-only: a `firmwares` singleton with the
  commit it is built from, its target and its Nerves system
  (`VisionCore.Firmware`).
  """
  use VisionApiWeb, :controller

  def show(conn, _params), do: render(conn, :show, firmware: VisionCore.Firmware.current())
end

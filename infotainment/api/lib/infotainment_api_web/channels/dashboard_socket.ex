defmodule InfotainmentApiWeb.DashboardSocket do
  use Phoenix.Socket

  ## Channels
  channel "speed", InfotainmentApiWeb.SpeedChannel
  channel "gear", InfotainmentApiWeb.GearChannel
  channel "car-overview", InfotainmentApiWeb.CarOverviewChannel

  def connect(_params, socket) do
    {:ok, socket}
  end

  def id(_socket), do: nil
end

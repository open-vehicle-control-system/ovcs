defmodule InfotainmentApiWeb.DashboardSocket do
  use Phoenix.Socket

  ## Channels
  channel "debug-metrics", InfotainmentApiWeb.DebugMetricsChannel
  channel "system-information", InfotainmentApiWeb.SystemInformationChannel
  channel "speed", InfotainmentApiWeb.SpeedChannel
  channel "gear", InfotainmentApiWeb.GearChannel
  channel "car-overview", InfotainmentApiWeb.CarOverviewChannel

  def connect(_params, socket) do
    {:ok, socket}
  end

  def id(_socket), do: nil
end

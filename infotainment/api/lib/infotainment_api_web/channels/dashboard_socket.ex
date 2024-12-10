defmodule InfotainmentApiWeb.DashboardSocket do
  use Phoenix.Socket

  ## Channels
  channel "status", InfotainmentApiWeb.StatusChannel
  channel "temperature", InfotainmentApiWeb.TemperatureChannel

  def connect(_params, socket) do
    {:ok, socket}
  end

  def id(_socket), do: nil
end

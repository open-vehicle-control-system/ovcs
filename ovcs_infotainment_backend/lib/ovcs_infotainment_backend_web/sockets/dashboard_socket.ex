defmodule OvcsInfotainmentBackendWeb.Sockets.DashboardSocket do
  use Phoenix.Socket

  ## Channels
  channel "debug-metrics", OvcsInfotainmentBackendWeb.Sockets.Dashboard.DebugMetricsChannel

  def connect(_params, socket) do
    {:ok, socket}
  end

  def id(_socket), do: nil
end

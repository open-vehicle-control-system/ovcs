defmodule OvcsInfotainmentBackendWeb.DashboardSocket do
  use Phoenix.Socket

  ## Channels
  channel "debug-metrics", OvcsInfotainmentBackendWeb.DebugMetricsChannel
  channel "system-information", OvcsInfotainmentBackendWeb.SystemInformationChannel

  def connect(_params, socket) do
    {:ok, socket}
  end

  def id(_socket), do: nil
end

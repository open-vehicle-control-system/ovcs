defmodule OvcsInfotainmentBackendWeb.Sockets.DashboardSocket do
  use Phoenix.Socket

  ## Channels
  channel "debug-metrics", OvcsInfotainmentBackendWeb.Sockets.Dashboard.DebugMetricsChannel
end

defmodule OvcsInfotainmentBackendWeb.Sockets.Dashboard.DebugMetricsChannel do
  use Phoenix.Channel

  def join("debug-metrics", _message, socket) do
    response  = %{socket: "jason"}
    {:reply, {:ok, response}, socket}
  end
end

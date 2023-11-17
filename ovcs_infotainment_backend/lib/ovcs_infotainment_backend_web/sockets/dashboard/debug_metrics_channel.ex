defmodule OvcsInfotainmentBackendWeb.Sockets.Dashboard.DebugMetricsChannel do
  use Phoenix.Channel

  def join("debug-metrics", _message, socket) do
    IO.inspect "Socket connected"
    {:ok, socket}
  end

  def handle_in("bootstrap", _attrs, socket) do
      response = %{sockay: "jason"}
      {:reply, {:ok, response}, socket}
  end
end

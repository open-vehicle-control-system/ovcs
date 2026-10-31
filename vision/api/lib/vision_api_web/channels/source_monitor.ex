defmodule VisionApiWeb.SourceMonitor do
  @moduledoc """
  Ties a channel to the `vision_core` server it subscribes to. A
  restarted server has forgotten its subscribers, so the channel stops
  with `:source_restarted` and the dashboard's client rejoins.

  A join while the server is not running is refused with
  `%{reason: "unavailable"}`, and the client retries it.
  """

  @unavailable {:error, %{reason: "unavailable"}}

  @doc """
  Monitors `server` from the calling channel, then runs `subscribe`.
  Monitoring first means a server that stops in between still stops the
  channel; see `handle_down/2`.
  """
  @spec join(Phoenix.Socket.t(), GenServer.server(), (-> :ok)) ::
          {:ok, Phoenix.Socket.t()} | {:error, %{reason: String.t()}}
  def join(socket, server, subscribe) do
    case GenServer.whereis(server) do
      nil ->
        @unavailable

      pid ->
        socket = Phoenix.Socket.assign(socket, :source_monitor, Process.monitor(pid))

        try do
          :ok = subscribe.()
          {:ok, socket}
        catch
          :exit, _reason ->
            Process.demonitor(socket.assigns.source_monitor, [:flush])
            @unavailable
        end
    end
  end

  @doc "The channel's reply to a `:DOWN` message."
  @spec handle_down(reference(), Phoenix.Socket.t()) ::
          {:stop, :source_restarted, Phoenix.Socket.t()} | {:noreply, Phoenix.Socket.t()}
  def handle_down(monitor_reference, %{assigns: %{source_monitor: monitor_reference}} = socket),
    do: {:stop, :source_restarted, socket}

  def handle_down(_monitor_reference, socket), do: {:noreply, socket}
end

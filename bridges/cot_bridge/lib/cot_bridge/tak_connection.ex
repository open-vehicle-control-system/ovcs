defmodule CotBridge.TakConnection do
  @moduledoc """
  Owns the socket to the TAK server and pushes CoT XML documents on
  it.

    * `:tcp` / `:tls` — persistent stream against the TAK "streaming
      CoT" inputs (typically `8087` plain, `8089` TLS with client
      certificates). The connection is (re)established on a backoff
      loop; a send failure tears the socket down and re-enters that
      loop.
    * `:udp` — fire-and-forget datagrams, one event per datagram
      (TAK UDP CoT input).

  Events sent while disconnected are dropped rather than queued —
  position is a live feed and the publisher re-renders a fresh event
  on the next tick anyway, so replaying stale samples after a
  reconnect would only draw the marker where the vehicle isn't.
  """
  use GenServer

  require Logger

  @reconnect_interval_ms 5_000
  @connect_timeout_ms 5_000

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc "Sends one CoT XML document. Drops silently when disconnected."
  def send_event(xml) do
    GenServer.cast(__MODULE__, {:send_event, xml})
  end

  @impl true
  def init(config) do
    send(self(), :connect)

    {:ok,
     %{
       host: String.to_charlist(config.tak_host),
       port: config.tak_port,
       protocol: config.protocol,
       ssl_options: config.ssl_options,
       socket: nil
     }}
  end

  @impl true
  def handle_info(:connect, %{protocol: :udp} = state) do
    {:ok, socket} = :gen_udp.open(0, [:binary])
    Logger.info("#{__MODULE__} sending to udp://#{state.host}:#{state.port}")
    {:noreply, %{state | socket: socket}}
  end

  def handle_info(:connect, %{protocol: :tcp} = state) do
    :gen_tcp.connect(state.host, state.port, [:binary, active: true], @connect_timeout_ms)
    |> handle_connection(state)
  end

  def handle_info(:connect, %{protocol: :tls} = state) do
    :ssl.connect(
      state.host,
      state.port,
      [:binary, active: true] ++ state.ssl_options,
      @connect_timeout_ms
    )
    |> handle_connection(state)
  end

  # TAK streaming connections are bidirectional — the server pushes
  # the other clients' CoT traffic back at us. Nothing to do with it
  # (yet), but the socket is active so the messages must be drained.
  def handle_info({:tcp, _socket, _data}, state), do: {:noreply, state}
  def handle_info({:ssl, _socket, _data}, state), do: {:noreply, state}

  def handle_info({closed, _socket}, state) when closed in [:tcp_closed, :ssl_closed] do
    Logger.warning("#{__MODULE__} connection to #{state.host}:#{state.port} closed, reconnecting")
    Process.send_after(self(), :connect, @reconnect_interval_ms)
    {:noreply, %{state | socket: nil}}
  end

  def handle_info({error, _socket, reason}, state) when error in [:tcp_error, :ssl_error] do
    Logger.warning("#{__MODULE__} connection error: #{inspect(reason)}, reconnecting")
    Process.send_after(self(), :connect, @reconnect_interval_ms)
    {:noreply, %{state | socket: nil}}
  end

  @impl true
  def handle_cast({:send_event, _xml}, %{socket: nil} = state) do
    {:noreply, state}
  end

  def handle_cast({:send_event, xml}, %{protocol: :udp} = state) do
    :gen_udp.send(state.socket, state.host, state.port, xml)
    {:noreply, state}
  end

  def handle_cast({:send_event, xml}, %{protocol: :tcp} = state) do
    :gen_tcp.send(state.socket, xml)
    |> handle_send_result(state)
  end

  def handle_cast({:send_event, xml}, %{protocol: :tls} = state) do
    :ssl.send(state.socket, xml)
    |> handle_send_result(state)
  end

  defp handle_connection({:ok, socket}, state) do
    Logger.info("#{__MODULE__} connected to #{state.protocol}://#{state.host}:#{state.port}")
    {:noreply, %{state | socket: socket}}
  end

  defp handle_connection({:error, reason}, state) do
    Logger.warning(
      "#{__MODULE__} could not reach #{state.protocol}://#{state.host}:#{state.port} " <>
        "(#{inspect(reason)}), retrying in #{@reconnect_interval_ms}ms"
    )

    Process.send_after(self(), :connect, @reconnect_interval_ms)
    {:noreply, state}
  end

  defp handle_send_result(:ok, state), do: {:noreply, state}

  defp handle_send_result({:error, reason}, state) do
    Logger.warning("#{__MODULE__} send failed: #{inspect(reason)}, reconnecting")
    close(state)
    Process.send_after(self(), :connect, @reconnect_interval_ms)
    {:noreply, %{state | socket: nil}}
  end

  defp close(%{socket: nil}), do: :ok
  defp close(%{protocol: :tcp, socket: socket}), do: :gen_tcp.close(socket)
  defp close(%{protocol: :tls, socket: socket}), do: :ssl.close(socket)
  defp close(%{protocol: :udp, socket: socket}), do: :gen_udp.close(socket)
end

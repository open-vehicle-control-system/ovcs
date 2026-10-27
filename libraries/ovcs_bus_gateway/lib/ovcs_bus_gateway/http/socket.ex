defmodule OvcsBusGateway.Http.Socket do
  @moduledoc """
  WebSocket handler streaming the signals matching a filter, server to client only.

  On connect it sends `{"type":"snapshot","signals":[...]}` with the cached envelopes, then
  `{"type":"update","signals":[...]}` for each dispatched batch that has matching envelopes.
  A client whose mailbox exceeds the queue limit is closed with code 1013.
  """

  @behaviour WebSock

  alias OvcsBusGateway.{Cache, Subscribers}

  @max_queue 1000
  # Pongs reset the server's read timeout, which would otherwise close a quiet stream.
  @ping_interval 30_000

  @impl WebSock
  def init(filter) do
    # Subscribing before reading the snapshot loses nothing in between.
    :ok = Subscribers.subscribe()
    schedule_ping()
    {:push, frame("snapshot", Cache.select(filter)), filter}
  end

  @impl WebSock
  def handle_in(_message, filter), do: {:ok, filter}

  @impl WebSock
  def handle_info({:ovcs_bus_gateway, envelopes}, filter) do
    {:message_queue_len, queue_len} = Process.info(self(), :message_queue_len)

    if queue_len > @max_queue do
      {:stop, :normal, {1013, "falling behind"}, filter}
    else
      case Enum.filter(envelopes, &matches?(&1, filter)) do
        [] -> {:ok, filter}
        matching -> {:push, frame("update", matching), filter}
      end
    end
  end

  def handle_info(:ping, filter) do
    schedule_ping()
    {:push, {:ping, ""}, filter}
  end

  def handle_info(_message, filter), do: {:ok, filter}

  defp schedule_ping do
    interval = Application.get_env(:ovcs_bus_gateway, :ping_interval, @ping_interval)
    Process.send_after(self(), :ping, interval)
  end

  defp matches?(envelope, filter) do
    Enum.all?(filter, fn {field, value} -> Map.fetch!(envelope, field) == value end)
  end

  defp frame(type, envelopes) do
    {:text, Jason.encode!(%{type: type, signals: envelopes})}
  end
end

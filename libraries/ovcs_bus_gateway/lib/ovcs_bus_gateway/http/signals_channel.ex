defmodule OvcsBusGateway.Http.SignalsChannel do
  @moduledoc """
  The `signals` channel: streams the envelopes matching the filter given as join params
  (`node`, `source`, `name`, each optional; a missing or empty one matches everything).

  After the join it pushes `snapshot` with `%{signals: [...]}`, the cached envelopes, then
  `update` with the matching envelopes of each dispatched batch, nothing for a batch without
  any. When the mailbox of the socket's transport process exceeds the queue limit, the
  channel pushes `overloaded` and stops; the client joins again for a fresh snapshot.
  """

  use Phoenix.Channel

  alias OvcsBusGateway.{Cache, Http, Subscribers}

  @max_queue 1000

  @impl Phoenix.Channel
  def join("signals", params, socket) do
    # Subscribing before the snapshot is read loses nothing in between.
    :ok = Subscribers.subscribe()
    send(self(), :push_snapshot)

    {:ok, assign(socket, filter: Http.filter(params), snapshot_pushed?: false)}
  end

  @impl Phoenix.Channel
  def handle_info(:push_snapshot, socket) do
    push(socket, "snapshot", %{signals: Cache.select(socket.assigns.filter)})
    {:noreply, assign(socket, :snapshot_pushed?, true)}
  end

  # The collector caches a batch before dispatching it, so the snapshot already holds it.
  def handle_info(
        {:ovcs_bus_gateway, _envelopes},
        %{assigns: %{snapshot_pushed?: false}} = socket
      ),
      do: {:noreply, socket}

  def handle_info({:ovcs_bus_gateway, envelopes}, socket) do
    if transport_queue_len(socket) > @max_queue do
      push(socket, "overloaded", %{})
      {:stop, :normal, socket}
    else
      case Enum.filter(envelopes, &matches?(&1, socket.assigns.filter)) do
        [] -> :ok
        matching -> push(socket, "update", %{signals: matching})
      end

      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Pushes queue in the socket's transport process, which writes them to the client.
  defp transport_queue_len(socket) do
    case Process.info(socket.transport_pid, :message_queue_len) do
      {:message_queue_len, queue_len} -> queue_len
      nil -> 0
    end
  end

  defp matches?(envelope, filter) do
    Enum.all?(filter, fn {field, value} -> Map.fetch!(envelope, field) == value end)
  end
end

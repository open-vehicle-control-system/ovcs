defmodule OvcsBusGateway.Http.StatusChannel do
  @moduledoc """
  The `status` channel: pushes `status` with `%{nodes: [...], adapters: [...]}` after the join,
  then again whenever a node or an adapter changes, checked once a second. A node is its `id`,
  `name`, `connected`, `signalCount` and `staleCount`; an adapter its `id` and its attributes
  in `/api/adapters`.
  """

  use Phoenix.Channel

  alias OvcsBusGateway.{Adapters, Cache, Nodes}
  alias OvcsBusGateway.Http.Json

  @check_interval 1_000

  @impl Phoenix.Channel
  def join("status", _params, socket) do
    send(self(), :check)
    {:ok, assign(socket, :status, nil)}
  end

  @impl Phoenix.Channel
  def handle_info(:check, socket) do
    Process.send_after(self(), :check, @check_interval)
    status = status()
    if status != socket.assigns.status, do: push(socket, "status", status)
    {:noreply, assign(socket, :status, status)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp status do
    %{
      nodes: Cache.select(%{}) |> Nodes.list() |> Enum.map(&Json.node_status/1),
      adapters: Enum.map(Adapters.list(), &Json.adapter_status/1)
    }
  end
end

defmodule VisionApiWeb.DashboardSocket do
  @moduledoc "The dashboard's socket: the `status` and `preview:<stream>` channels."
  use Phoenix.Socket

  channel "status", VisionApiWeb.StatusChannel
  channel "preview:*", VisionApiWeb.PreviewChannel

  @impl Phoenix.Socket
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl Phoenix.Socket
  def id(_socket), do: nil
end

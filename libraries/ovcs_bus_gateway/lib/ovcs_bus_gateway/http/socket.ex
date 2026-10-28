defmodule OvcsBusGateway.Http.Socket do
  @moduledoc """
  Phoenix Channels socket of `OvcsBusGateway.Http`, mounted at `/socket`, with the `signals`
  channel, `OvcsBusGateway.Http.SignalsChannel`.
  """

  use Phoenix.Socket

  channel "signals", OvcsBusGateway.Http.SignalsChannel

  @impl Phoenix.Socket
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl Phoenix.Socket
  def id(_socket), do: nil
end

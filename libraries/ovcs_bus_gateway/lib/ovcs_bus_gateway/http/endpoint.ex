defmodule OvcsBusGateway.Http.Endpoint do
  @moduledoc """
  Phoenix endpoint of `OvcsBusGateway.Http`, configured by its child spec.
  """

  use Phoenix.Endpoint, otp_app: :ovcs_bus_gateway

  # Clients reach the gateway by whatever address the vehicle network gives it.
  socket "/socket", OvcsBusGateway.Http.Socket,
    websocket: [check_origin: false],
    longpoll: false

  plug Plug.Static,
    at: "/",
    from: {:ovcs_bus_gateway, "priv/static"},
    only: ~w(assets favicon.ico)

  plug OvcsBusGateway.Http.Router
end

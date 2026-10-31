defmodule VisionApiWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :vision_api

  plug Plug.Static,
    at: "/",
    from: :vision_api,
    gzip: false,
    only: VisionApiWeb.static_paths()

  socket "/sockets/dashboard", VisionApiWeb.DashboardSocket,
    websocket: true,
    longpoll: false

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.Head
  # The dashboard's Vite dev server runs on another origin.
  plug CORSPlug
  plug VisionApiWeb.Router
end

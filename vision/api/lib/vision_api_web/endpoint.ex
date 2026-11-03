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

  # The dashboard polls the parameters: logged, the polls would push everything else out of the log.
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint], log: :debug

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.Head

  if Application.compile_env(:vision_api, :allow_cross_origin, false) do
    plug CORSPlug
  end

  plug VisionApiWeb.Router
end

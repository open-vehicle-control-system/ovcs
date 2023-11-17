defmodule OvcsInfotainmentBackendWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :ovcs_infotainment_backend

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_ovcs_infotainment_backend_key",
    signing_salt: "F4n9imac",
    same_site: "Lax"
  ]

  #socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :ovcs_infotainment_backend,
    gzip: false,
    only: OvcsInfotainmentBackendWeb.static_paths()

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :ovcs_infotainment_backend
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug CORSPlug, origin: ["*"]
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  socket "/sockets/dashboard", OvcsInfotainmentBackendWeb.Sockets.DashboardSocket,
    websocket: true,
    longpoll: false
  plug OvcsInfotainmentBackendWeb.Router
end

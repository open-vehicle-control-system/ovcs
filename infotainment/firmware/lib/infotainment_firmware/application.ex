defmodule InfotainmentFirmware.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    opts = [strategy: :rest_for_one, name: Example.Supervisor]
    children = [
      {NervesFlutterpi,
        flutter_app_dir: "/var/flutter_assets",
        name: :flutterpi},
    ]
    Supervisor.start_link(children, opts)
  end

  def target() do
    Application.get_env(:infotainment_firmware, :target)
  end
end

defmodule InfotainmentFirmware.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    wait_for_drm()
  end

  def target() do
    Application.get_env(:infotainment_firmware, :target)
  end

  def start_infotainment() do
    opts = [strategy: :rest_for_one, name: Example.Supervisor]
    children = [
      {NervesFlutterpi,
        flutter_app_dir: "/var/flutter_assets",
        name: :flutterpi},
    ]
    Supervisor.start_link(children, opts)
  end

  def wait_for_drm() do
    if NervesUEvent.get(["devices", "platform", "gpu", "drm", "card1"]) == nil do
      Logger.info("Waiting for DRM device to be ready")
      Process.sleep(500)
      wait_for_drm()
    else
      start_infotainment()
    end
  end
end

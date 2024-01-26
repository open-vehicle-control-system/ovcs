defmodule OvcsInfotainmentFirmware.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @xdg_runtime_dir "/tmp/nerves_weston"

  @impl true
  def start(_type, _args) do
    children = [
      {NervesWeston,
        xdg_runtime_dir: @xdg_runtime_dir,
        name: :weston,
        cli_args: [
          "--config=/etc/weston.ini"
        ]
      },
      {NervesCog,
       url: "http://localhost:4000/",
       fullscreen: true,
       xdg_runtime_dir: @xdg_runtime_dir,
       wayland_display: "wayland-1",
       name: :cog}
    ]

    opts = [strategy: :rest_for_one, name: Example.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def target() do
    Application.get_env(:nerves_ovcs, :target)
  end
end

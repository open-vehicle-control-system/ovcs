defmodule InfotainmentFirmware.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: Example.Supervisor]
    children = [
      {NervesFlutterpi,
        flutter_app_dir: "/var/flutter_assets",
        name: :flutterpi},
    ]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def start_phase(:load_and_start_apps, _start_type, _args) do
    load_and_start_apps(:infotainment_api)
  end

  def load_and_start_apps(application) do
    case Application.ensure_all_started(application) do
      {:ok, _} ->
        Logger.info("#{application} started successfully!")
      {:error, :nomatch} ->
        Logger.warning("#{application} could not start, continuing without it.")
    end
    :ok
  end

  def target() do
    Application.get_env(:infotainment_firmware, :target)
  end
end

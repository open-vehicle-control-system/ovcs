defmodule InfotainmentCore.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    vehicle_children = vehicle_composer().children()

    children =
      [
        InfotainmentCore.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:infotainment_core, :ecto_repos), skip: skip_migrations?()},
        {InfotainmentCore.Temperature, []},
        {InfotainmentCore.TimeSettings, []}
      ] ++ bus_relay_children() ++ vehicle_children

    opts = [strategy: :one_for_one, name: InfotainmentCore.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def vehicle_composer do
    Application.fetch_env!(:infotainment_core, :vehicle)
  end

  defp skip_migrations? do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") != nil
  end

  # Opt-in MQTT bus relay — started only when the vehicle's
  # infotainment composer implements `bus_relay/0` and returns
  # non-nil opts.
  defp bus_relay_children do
    composer = vehicle_composer()

    if function_exported?(composer, :bus_relay, 0) do
      case composer.bus_relay() do
        nil -> []
        opts -> [{OvcsBus.Mqtt.Relay, opts}]
      end
    else
      []
    end
  end
end

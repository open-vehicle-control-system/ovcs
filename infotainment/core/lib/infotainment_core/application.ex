defmodule InfotainmentCore.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    composer = vehicle_composer()
    vehicle_children = composer.children()

    children =
      [
        InfotainmentCore.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:infotainment_core, :ecto_repos), skip: skip_migrations?()},
        {InfotainmentCore.Temperature, []},
        {InfotainmentCore.TimeSettings, []}
      ] ++ cluster_child() ++ vehicle_children

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

  defp cluster_child do
    case Application.get_env(:ovcs_vehicle, :module) do
      nil -> []
      mod -> [{OvcsBus.Cluster, vehicle: mod}]
    end
  end
end

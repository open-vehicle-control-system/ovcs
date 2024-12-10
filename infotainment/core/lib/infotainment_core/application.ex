defmodule InfotainmentCore.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      #InfotainmentCore.Repo,
      #{Ecto.Migrator,
      #  repos: Application.fetch_env!(:vms_core, :ecto_repos),
      #  skip: skip_migrations?()},
      {InfotainmentCore.VehicleStatus, []},
      {InfotainmentCore.Temperature, []}

    ]

    opts = [strategy: :one_for_one, name: InfotainmentCore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

defmodule VmsCore.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    if Application.get_env(:vms_core, :load_debugger_dependencies) do
      load_debugger_dependencies()
    end

    vehicle_children = vehicle_compposer().children()
    children = [
      VmsCore.Repo,
      {Ecto.Migrator,
        repos: Application.fetch_env!(:vms_core, :ecto_repos),
        skip: skip_migrations?()},
      {Phoenix.PubSub, name: VmsCore.Bus},
      {VmsCore.Metrics, []},
      {VmsCore.NetworkInterfaces, []},
    ]
    children =  case Application.get_env(:vms_core, :socketcand_only) do
      true -> []
      false -> children ++ vehicle_children
    end
    opts = [strategy: :one_for_one, name: VmsCore.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp skip_migrations? do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") != nil
  end

  defp load_debugger_dependencies do
    Mix.ensure_application!(:wx)
    Mix.ensure_application!(:runtime_tools)
    Mix.ensure_application!(:observer)
  end

  def vehicle_compposer do
    VmsCore.Vehicles
      |> Module.concat(Application.get_env(:vms_core, :vehicle))
      |> Module.concat(Composer)
  end
end

defmodule VmsCore.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    if Application.get_env(:vms_core, :load_debugger_dependencies) do
      load_debugger_dependencies()
    end

    composer = vehicle_composer()
    vehicle_children = composer.children()

    children =
      [
        VmsCore.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:vms_core, :ecto_repos), skip: skip_migrations?()},
        {VmsCore.Metrics, []},
        {VmsCore.NetworkInterfaces, []}
      ] ++ cluster_child()

    children =
      case Application.get_env(:vms_core, :socketcand_only) do
        true -> []
        false -> children ++ vehicle_children
      end

    opts = [strategy: :one_for_one, name: VmsCore.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # A release's start script sets `RELEASE_NAME`; migrations are skipped there.
  defp skip_migrations? do
    System.get_env("RELEASE_NAME") != nil
  end

  defp load_debugger_dependencies do
    Mix.ensure_application!(:wx)
    Mix.ensure_application!(:runtime_tools)
    Mix.ensure_application!(:observer)
  end

  @doc """
  The vehicle's VMS composer, a `VmsCore.Vehicle` module, set by the
  firmware's `config/runtime.exs`.
  """
  def vehicle_composer do
    Application.fetch_env!(:vms_core, :vehicle)
  end

  # Without a selected vehicle the cluster has no peers to probe for.
  defp cluster_child do
    case Application.get_env(:ovcs_vehicle, :module) do
      nil -> []
      vehicle_module -> [{OvcsBus.Cluster, vehicle: vehicle_module}]
    end
  end
end

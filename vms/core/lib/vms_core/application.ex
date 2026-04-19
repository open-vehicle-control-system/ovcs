defmodule VmsCore.Application do
  @moduledoc false

  use Application

  @impl true
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
      ] ++
        cluster_child() ++
        OvcsBus.Mqtt.broker_child_from(composer) ++
        OvcsBus.Mqtt.relay_child_from(composer)

    children =
      case Application.get_env(:vms_core, :socketcand_only) do
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

  def vehicle_composer do
    Application.fetch_env!(:vms_core, :vehicle)
  end

  # Supervise `OvcsBus.Cluster` when `:ovcs_vehicle, :module` is set —
  # each firmware's `runtime.exs` sets this to the top-level vehicle
  # module (e.g. `Ovcs1`) whenever a vehicle is selected. Without it
  # the cluster helper has nothing to probe for, so skip.
  defp cluster_child do
    case Application.get_env(:ovcs_vehicle, :module) do
      nil -> []
      mod -> [{OvcsBus.Cluster, vehicle: mod}]
    end
  end
end

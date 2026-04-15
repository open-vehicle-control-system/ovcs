defmodule VmsCore.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    if Application.get_env(:vms_core, :load_debugger_dependencies) do
      load_debugger_dependencies()
    end

    vehicle_children = vehicle_composer().children()
    children = [
      VmsCore.Repo,
      {Ecto.Migrator,
        repos: Application.fetch_env!(:vms_core, :ecto_repos),
        skip: skip_migrations?()},
      {VmsCore.Metrics, []},
      {VmsCore.NetworkInterfaces, []},
    ] ++ bus_broker_children() ++ bus_relay_children()
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

  def vehicle_composer do
    Application.fetch_env!(:vms_core, :vehicle)
  end

  # Opt-in MQTT bus relay — started only when the vehicle's VMS
  # composer implements `bus_relay/0` and returns non-nil opts.
  defp bus_relay_children do
    composer = vehicle_composer()

    if function_exported?(composer, :bus_relay, 0) do
      case composer.bus_relay() do
        nil -> []
        opts -> [{OvcsBus.Relay.Mqtt, opts}]
      end
    else
      []
    end
  end

  # Opt-in MQTT broker — started only when the vehicle's VMS
  # composer implements `bus_broker/0` and returns non-nil opts.
  # This is the broker all other firmwares' relays connect to.
  defp bus_broker_children do
    composer = vehicle_composer()

    if function_exported?(composer, :bus_broker, 0) do
      case composer.bus_broker() do
        nil -> []
        opts -> [{OvcsBus.Broker, opts}]
      end
    else
      []
    end
  end
end

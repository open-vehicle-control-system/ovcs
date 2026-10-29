defmodule VisionCore.Application do
  @moduledoc """
  Starts the vision pipeline the vehicle's `VisionCore.Composer` declares.

  The composer is the `:vision_core, :vehicle` app env, set by the vision
  firmware's `config/runtime.exs`. With none set nothing starts.

  The pipeline is one `:rest_for_one` supervisor, `VisionCore.Supervisor`,
  with `VisionCore.Ros2.ZenohClient` first. Consumers subscribe only from
  `init/1`, so they must restart with the client to get their
  subscriptions back. `VisionCore.Status` and `VisionCore.Preview`, the
  dashboard's sources, start after the components.
  """
  use Application

  # Not the app env: `stop/1` runs while the application controller is
  # stopping the app, so a call to it from there times out.
  @active_config {__MODULE__, :active_config}

  @impl Application
  def start(_type, _args) do
    children =
      case Application.get_env(:vision_core, :vehicle) do
        nil ->
          []

        composer ->
          config = composer.config(VisionCore.arm())
          :persistent_term.put(@active_config, config)
          cluster_child() ++ [pipeline_child(config)]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: VisionCore.AppSupervisor)
  end

  @impl Application
  def stop(_state), do: :persistent_term.erase(@active_config)

  @doc "The `VisionCore.Config` the running pipeline started with, or `nil`."
  @spec active_config() :: VisionCore.Config.t() | nil
  def active_config, do: :persistent_term.get(@active_config, nil)

  defp pipeline_child(%VisionCore.Config{} = config) do
    core_children = [
      {VisionCore.Ros2.ZenohClient, zenoh_client_opts(config)},
      VisionCore.Ros2.Parameters,
      VisionCore.Jpeg
    ]

    component_children = Enum.flat_map(config.components, &resolve_component/1)
    # Last, so they register on the components while starting.
    dashboard_children = [
      {VisionCore.Status, config: config},
      {VisionCore.Preview, config: config}
    ]

    %{
      id: VisionCore.Supervisor,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           core_children ++ component_children ++ dashboard_children,
           [strategy: :rest_for_one, name: VisionCore.Supervisor]
         ]}
    }
  end

  # Omit `:node_name` when unset so `ZenohClient` applies its default.
  defp zenoh_client_opts(%VisionCore.Config{node_name: nil} = config),
    do: [endpoint_ip: config.zenoh_endpoint_ip]

  defp zenoh_client_opts(%VisionCore.Config{} = config),
    do: [endpoint_ip: config.zenoh_endpoint_ip, node_name: config.node_name]

  defp resolve_component(name) when is_atom(name), do: VisionCore.Components.start(name, [])

  defp resolve_component({name, opts}) when is_atom(name),
    do: VisionCore.Components.start(name, opts)

  # Without a selected vehicle the cluster has no peers to probe for.
  defp cluster_child do
    case Application.get_env(:ovcs_vehicle, :module) do
      nil -> []
      vehicle_module -> [{OvcsBus.Cluster, vehicle: vehicle_module}]
    end
  end
end

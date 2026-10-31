defmodule VisionCore.Application do
  @moduledoc """
  Starts the vision pipeline the vehicle's `VisionCore.Composer` declares.

  The composer is the `:vision_core, :vehicle` app env, set by the vision
  firmware's `config/runtime.exs`. With none set nothing starts.

  The pipeline is one `:rest_for_one` supervisor, `VisionCore.Supervisor`.
  `VisionCore.Parameters.Storage` and the `VisionCore.Parameters` registry
  come first, so saved values are loaded before any component declares its
  parameters and a restart of anything after them keeps the unsaved changes.
  `VisionCore.Ros2.ZenohClient` follows them. Consumers subscribe only from
  `init/1`, so they must restart with the client to get their subscriptions
  back. The Port servers, `VisionCore.Jpeg` and
  `VisionCore.Stereo.Matcher`, start before the components and open their
  Ports on the first request, so a unit that computes no stereo stage
  natively never starts `stereo_match`. `VisionCore.Ros2.Topics`, which counts what
  the components publish, starts before them. `VisionCore.Status` and
  `VisionCore.Preview`, the dashboard's sources, start after the components.
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
      VisionCore.Parameters.Storage,
      VisionCore.Parameters,
      {VisionCore.Ros2.ZenohClient, zenoh_client_opts(config)},
      VisionCore.Ros2.Parameters,
      VisionCore.Jpeg,
      VisionCore.Stereo.Matcher,
      VisionCore.Ros2.Topics
    ]

    component_children = Enum.flat_map(config.components, &resolve_component/1)
    # Last, so they register on the components while starting.
    dashboard_children = [
      {VisionCore.Status, config: config},
      {VisionCore.Preview, [config: config] ++ config.preview}
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

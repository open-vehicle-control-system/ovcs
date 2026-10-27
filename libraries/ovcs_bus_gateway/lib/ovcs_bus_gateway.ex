defmodule OvcsBusGateway do
  @moduledoc """
  Bridge library that exposes the signals of the OVCS bus to outside
  consumers over MQTT and HTTP/WebSocket. Hosted by the shared
  `bridges/firmware` image; vehicles opt in via their
  `bridge_firmwares/0` map.

  Vehicles that bundle this bridge implement
  `c:ovcs_bus_gateway_config/1`, returning an `OvcsBusGateway.Config`
  that selects the adapters and the forwarding interval. The bridge
  passes the active `:host`/`:target` arm.

  `children/0` returns one `:rest_for_one` subtree: the subscriber
  registry, the cache, the collector, then the configured adapters, so
  a restart of an upstream child restarts everything that depends on it.
  The subtree is `:temporary` with its own restart intensity: a gateway
  that exhausts it stops alone, without restarting the bridge supervisor
  it shares with the other bridges.
  """
  @behaviour OvcsBridge

  @typedoc "Selects signals by `:node`, `:source` and `:name`; a missing key matches everything."
  @type filter :: %{optional(:node | :source | :name) => String.t()}

  @doc "Per-deployment gateway config for the active arm."
  @callback ovcs_bus_gateway_config(arm :: :host | :target) :: OvcsBusGateway.Config.t()

  # Read at compile time: on a Nerves device `Mix.target()` returns
  # `:host` at runtime, which would pick the wrong config arm.
  @arm if Mix.target() == :host, do: :host, else: :target

  @impl OvcsBridge
  def children, do: children(vehicle(), @arm, firmware_id())

  @doc """
  The supervision subtree for `vehicle` on `arm`, in the bridge firmware
  `firmware_id`; `children/0` calls it with the configured vehicle and
  firmware id and the compile-time arm.
  """
  @spec children(module(), :host | :target, String.t()) :: [Supervisor.child_spec()]
  def children(vehicle, arm, firmware_id) do
    config = vehicle.ovcs_bus_gateway_config(arm)

    core_children = [
      OvcsBusGateway.Subscribers,
      OvcsBusGateway.Cache,
      {OvcsBusGateway.Collector,
       vehicle: vehicle, forwarder_opts: [interval: config.forward_interval]}
    ]

    [
      %{
        id: OvcsBusGateway.Supervisor,
        type: :supervisor,
        restart: :temporary,
        start:
          {Supervisor, :start_link,
           [
             core_children ++
               http_children(config) ++
               mqtt_children(mqtt_client_id(vehicle, firmware_id, arm), vehicle, config),
             [
               strategy: :rest_for_one,
               max_restarts: 10,
               max_seconds: 60,
               name: OvcsBusGateway.Supervisor
             ]
           ]}
      }
    ]
  end

  @doc "The `<vehicle>` topic segment: the underscored vehicle module name."
  @spec vehicle_id(module()) :: String.t()
  def vehicle_id(vehicle), do: Macro.underscore(inspect(vehicle))

  @doc """
  The MQTT client id of the gateway in the bridge firmware `firmware_id`
  on `arm`, unique per vehicle, bridge firmware and arm on one broker.
  """
  @spec mqtt_client_id(module(), String.t(), :host | :target) :: String.t()
  def mqtt_client_id(vehicle, firmware_id, arm),
    do: "ovcs_bus_gateway_#{vehicle_id(vehicle)}_#{firmware_id}_#{arm}"

  defp mqtt_children(_client_id, _vehicle, %OvcsBusGateway.Config{mqtt: nil}), do: []

  defp mqtt_children(client_id, vehicle, %OvcsBusGateway.Config{mqtt: mqtt}),
    do: [{OvcsBusGateway.Mqtt, [vehicle: vehicle, client_id: client_id] ++ mqtt}]

  defp http_children(%OvcsBusGateway.Config{http: nil}), do: []
  defp http_children(%OvcsBusGateway.Config{http: http}), do: [{OvcsBusGateway.Http, http}]

  # Set by bridges/firmware's runtime.exs; fetch! so a misconfigured boot fails loudly.
  defp vehicle, do: Application.fetch_env!(:ovcs_vehicle, :module)

  # Same source as OvcsBridge.Supervisor, which fails the boot when neither is set.
  defp firmware_id,
    do: System.get_env("BRIDGE_FIRMWARE_ID") || Application.fetch_env!(:ovcs_bridge, :firmware_id)
end

defmodule OvcsBusGateway do
  @moduledoc """
  Exposes the signals of the OVCS bus to outside consumers over MQTT, HTTP
  and Phoenix Channels. Any OVCS firmware hosts it by adding its child spec
  to a supervisor of a BEAM in the vehicle's mesh:

      {OvcsBusGateway, vehicle: OvcsMini, config: %OvcsBusGateway.Config{}}

  Options:

    * `:vehicle` (required) - the vehicle module, which names the node
      roles and the `<vehicle>` MQTT topic segment.
    * `:config` - an `OvcsBusGateway.Config`, default `%OvcsBusGateway.Config{}`.
    * `:mqtt_client_id` - the MQTT client id, unique per gateway on one
      broker; default `"ovcs_bus_gateway_<vehicle>"`.

  The child is one `:rest_for_one` subtree: the subscriber registry, the
  cache, the collector, then the configured adapters, so a restart of an
  upstream child restarts everything that depends on it. The subtree is
  `:temporary` with its own restart intensity: a gateway that exhausts it
  stops alone, without restarting its parent.

  Its processes are registered under fixed names, so a BEAM runs one gateway.
  """

  @typedoc "Selects signals by `:node`, `:source` and `:name`; a missing key matches everything."
  @type filter :: %{optional(:node | :source | :name) => String.t()}

  @type option ::
          {:vehicle, module()}
          | {:config, OvcsBusGateway.Config.t()}
          | {:mqtt_client_id, String.t()}

  @doc "The gateway's supervision subtree; see the module documentation for `opts`."
  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(opts) do
    vehicle = Keyword.fetch!(opts, :vehicle)
    config = Keyword.get(opts, :config, %OvcsBusGateway.Config{})

    mqtt_client_id =
      Keyword.get(opts, :mqtt_client_id, "ovcs_bus_gateway_" <> vehicle_id(vehicle))

    core_children = [
      OvcsBusGateway.Subscribers,
      OvcsBusGateway.Cache,
      {OvcsBusGateway.Collector,
       vehicle: vehicle, forwarder_opts: [interval: config.forward_interval]}
    ]

    %{
      id: __MODULE__,
      type: :supervisor,
      restart: :temporary,
      start:
        {Supervisor, :start_link,
         [
           core_children ++
             http_children(config) ++ mqtt_children(mqtt_client_id, vehicle, config),
           [
             strategy: :rest_for_one,
             max_restarts: 10,
             max_seconds: 60,
             name: OvcsBusGateway.Supervisor
           ]
         ]}
    }
  end

  @doc "The `<vehicle>` topic segment: the underscored vehicle module name."
  @spec vehicle_id(module()) :: String.t()
  def vehicle_id(vehicle), do: Macro.underscore(inspect(vehicle))

  defp mqtt_children(_client_id, _vehicle, %OvcsBusGateway.Config{mqtt: nil}), do: []

  defp mqtt_children(client_id, vehicle, %OvcsBusGateway.Config{mqtt: mqtt}),
    do: [{OvcsBusGateway.Mqtt, [vehicle: vehicle, client_id: client_id] ++ mqtt}]

  defp http_children(%OvcsBusGateway.Config{http: nil}), do: []
  defp http_children(%OvcsBusGateway.Config{http: http}), do: [{OvcsBusGateway.Http, http}]
end

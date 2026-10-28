defmodule OvcsBusGatewayTest do
  use ExUnit.Case, async: true

  @mqtt_config %OvcsBusGateway.Config{mqtt: [host: "127.0.0.1", port: 1883]}

  defp supervisor(opts) do
    assert %{
             id: OvcsBusGateway,
             start: {OvcsBusGateway, :start_link, [children, supervisor_opts]}
           } =
             spec = OvcsBusGateway.child_spec(opts)

    {spec, children, supervisor_opts}
  end

  defp children(opts) do
    {_spec, children, _supervisor_opts} = supervisor(opts)
    children
  end

  defp child_ids(opts), do: opts |> children() |> Enum.map(&child_id/1)

  defp child_id({module, _opts}), do: module
  defp child_id(module) when is_atom(module), do: module

  test "an exhausted gateway stops alone instead of restarting its parent" do
    {spec, _children, supervisor_opts} = supervisor(vehicle: OvcsMini)

    assert spec.restart == :temporary
    assert spec.type == :supervisor
    assert supervisor_opts[:strategy] == :rest_for_one
    assert supervisor_opts[:max_restarts] == 10
    assert supervisor_opts[:max_seconds] == 60
  end

  test "defaults to the collector and the HTTP adapter" do
    assert child_ids(vehicle: OvcsMini) == [
             OvcsBusGateway.Subscribers,
             OvcsBusGateway.Cache,
             OvcsBusGateway.Collector,
             OvcsBusGateway.Http
           ]
  end

  test "adds the MQTT adapter last when configured" do
    assert child_ids(vehicle: OvcsMini, config: @mqtt_config) == [
             OvcsBusGateway.Subscribers,
             OvcsBusGateway.Cache,
             OvcsBusGateway.Collector,
             OvcsBusGateway.Http,
             OvcsBusGateway.Mqtt
           ]
  end

  test "skips HTTP when disabled" do
    refute OvcsBusGateway.Http in child_ids(
             vehicle: OvcsMini,
             config: %OvcsBusGateway.Config{http: nil}
           )
  end

  test "passes the vehicle and forward interval to the collector" do
    assert {OvcsBusGateway.Collector, [vehicle: OvcsMini, forwarder_opts: [interval: 20]]} in children(
             vehicle: OvcsMini
           )
  end

  test "the MQTT client id defaults to one per vehicle" do
    assert {OvcsBusGateway.Mqtt,
            [
              client_id: "ovcs_bus_gateway_ovcs_mini",
              host: "127.0.0.1",
              port: 1883
            ]} in children(
             vehicle: OvcsMini,
             config: @mqtt_config
           )
  end

  test "takes an explicit MQTT client id" do
    assert {OvcsBusGateway.Mqtt, [client_id: "gateway_ros", host: "127.0.0.1", port: 1883]} in children(
             vehicle: OvcsMini,
             config: @mqtt_config,
             mqtt_client_id: "gateway_ros"
           )
  end

  test "vehicle_id/1 is the underscored module name" do
    assert OvcsBusGateway.vehicle_id(OvcsMini) == "ovcs_mini"
  end
end

defmodule OvcsBusGatewayTest do
  use ExUnit.Case, async: true

  defmodule DefaultVehicle do
    @behaviour OvcsBusGateway

    @impl OvcsBusGateway
    def ovcs_bus_gateway_config(_arm), do: %OvcsBusGateway.Config{}
  end

  defmodule MqttVehicle do
    @behaviour OvcsBusGateway

    @impl OvcsBusGateway
    def ovcs_bus_gateway_config(_arm),
      do: %OvcsBusGateway.Config{mqtt: [host: "127.0.0.1", port: 1883]}
  end

  defmodule NoHttpVehicle do
    @behaviour OvcsBusGateway

    @impl OvcsBusGateway
    def ovcs_bus_gateway_config(_arm), do: %OvcsBusGateway.Config{http: nil}
  end

  defp supervisor_children(vehicle, arm) do
    assert [%{id: OvcsBusGateway.Supervisor, start: {Supervisor, :start_link, [children, opts]}}] =
             OvcsBusGateway.children(vehicle, arm, "ros")

    assert opts[:strategy] == :rest_for_one
    children
  end

  test "an exhausted gateway stops alone instead of restarting its parent" do
    assert [%{restart: :temporary, start: {Supervisor, :start_link, [_children, opts]}}] =
             OvcsBusGateway.children(DefaultVehicle, :host, "ros")

    assert opts[:max_restarts] == 10
    assert opts[:max_seconds] == 60
  end

  defp child_ids(vehicle, arm) do
    vehicle
    |> supervisor_children(arm)
    |> Enum.map(&child_id/1)
  end

  defp child_id({module, _opts}), do: module
  defp child_id(module) when is_atom(module), do: module

  test "defaults to the collector and the HTTP adapter" do
    assert child_ids(DefaultVehicle, :host) == [
             OvcsBusGateway.Subscribers,
             OvcsBusGateway.Cache,
             OvcsBusGateway.Collector,
             OvcsBusGateway.Http
           ]
  end

  test "adds the MQTT adapter last when configured" do
    assert child_ids(MqttVehicle, :target) == [
             OvcsBusGateway.Subscribers,
             OvcsBusGateway.Cache,
             OvcsBusGateway.Collector,
             OvcsBusGateway.Http,
             OvcsBusGateway.Mqtt
           ]
  end

  test "skips HTTP when disabled" do
    refute OvcsBusGateway.Http in child_ids(NoHttpVehicle, :host)
  end

  test "passes the vehicle and forward interval to the collector" do
    children = supervisor_children(MqttVehicle, :host)

    assert {OvcsBusGateway.Collector, [vehicle: MqttVehicle, forwarder_opts: [interval: 20]]} in children

    assert {OvcsBusGateway.Mqtt,
            [
              vehicle: MqttVehicle,
              client_id: "ovcs_bus_gateway_#{OvcsBusGateway.vehicle_id(MqttVehicle)}_ros_host",
              host: "127.0.0.1",
              port: 1883
            ]} in children
  end

  test "the MQTT client id names the vehicle, the bridge firmware and the arm" do
    assert OvcsBusGateway.mqtt_client_id(OvcsMini, "ros", :target) ==
             "ovcs_bus_gateway_ovcs_mini_ros_target"
  end

  test "vehicle_id/1 is the underscored module name" do
    assert OvcsBusGateway.vehicle_id(OvcsMini) == "ovcs_mini"
  end
end

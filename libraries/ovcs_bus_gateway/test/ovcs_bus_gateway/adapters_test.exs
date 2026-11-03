defmodule OvcsBusGateway.AdaptersTest do
  use ExUnit.Case, async: false

  alias OvcsBusGateway.{Adapters, Config, Mqtt, Settings, Subscribers}

  setup do
    start_supervised!(Subscribers)
    :ok
  end

  defp start_settings(config) do
    start_supervised!(
      {Settings, %Settings{vehicle: OvcsMini, config: config, mqtt_client_id: "gateway"}}
    )
  end

  defp adapter(id), do: Enum.find(Adapters.list(), &(&1.id == id))

  test "lists MQTT, then HTTP" do
    start_settings(%Config{})
    assert Enum.map(Adapters.list(), & &1.id) == ["mqtt", "http"]
  end

  test "reports MQTT off without a broker in the configuration" do
    start_settings(%Config{mqtt: nil})

    assert adapter("mqtt").status == %{level: :off, detail: "No broker in the configuration"}
    refute Map.has_key?(adapter("mqtt"), :broker)
  end

  test "describes a configured MQTT, in warning while it is not connected" do
    start_settings(%Config{mqtt: [host: "10.42.0.1", port: 1883]})

    assert %{
             status: %{level: :warning, detail: "Not running"},
             broker: "10.42.0.1:1883",
             client_id: "gateway",
             topic: "ovcs/<node>/<source>/<name>",
             module: Mqtt
           } = adapter("mqtt")
  end

  test "reports MQTT connected once its connection is up" do
    start_settings(%Config{mqtt: [host: "10.42.0.1", port: 1883]})
    start_supervised!(OvcsBusGateway.Cache)

    connect = fn _client, _host, _port ->
      {:ok, spawn_link(fn -> Process.sleep(:infinity) end)}
    end

    pid =
      start_supervised!(
        {Mqtt,
         client_id: "gateway",
         host: "10.42.0.1",
         port: 1883,
         connect: connect,
         publish: fn _, _, _, _ -> :ok end}
      )

    send(pid, {{Tortoise311, "gateway"}, :status, :up})

    assert adapter("mqtt").status == %{level: :ok, detail: "Connected to 10.42.0.1:1883"}
  end

  test "reports HTTP answering on its port, with the signals channels joined" do
    start_settings(%Config{http: [port: 4200]})
    Subscribers.subscribe(:signals_channel)
    Subscribers.subscribe(:mqtt)

    assert %{status: %{level: :ok, detail: "Answering on port 4200"}, port: 4200, clients: 1} =
             adapter("http")
  end

  test "reports HTTP off without a port in the configuration" do
    start_settings(%Config{http: nil})
    assert adapter("http").status.level == :off
  end
end

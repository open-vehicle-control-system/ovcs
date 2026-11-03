defmodule OvcsBusGateway.Http.StatusChannelTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  alias OvcsBusGateway.{Cache, Config, Envelope, Settings, Subscribers}
  alias OvcsBusGateway.Http.{Endpoint, Socket, StatusChannel}

  @endpoint Endpoint

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:phoenix)
    :ok
  end

  setup do
    start_supervised!(Subscribers)
    start_supervised!(Cache)

    start_supervised!(
      {Settings,
       %Settings{vehicle: OvcsMini, config: %Config{mqtt: nil}, mqtt_client_id: "gateway"}}
    )

    start_supervised!({Phoenix.PubSub, name: OvcsBusGateway.PubSub})
    start_supervised!({Endpoint, server: false, pubsub_server: OvcsBusGateway.PubSub})
    Cache.put_all([presence(true), speed()])
    :ok
  end

  defp presence(connected?) do
    %Envelope{
      node: "vms",
      source: "OvcsBusGateway.Collector",
      name: "connected",
      value: connected?,
      changed_at: 0,
      published_at: 0
    }
  end

  defp speed,
    do: %Envelope{
      node: "vms",
      source: "A",
      name: "speed",
      value: 1,
      changed_at: 0,
      published_at: 5
    }

  defp join do
    {:ok, _reply, socket} = Socket |> socket() |> subscribe_and_join(StatusChannel, "status", %{})
    socket
  end

  test "pushes the nodes and the adapters after the join" do
    join()

    assert_push "status", %{nodes: [node], adapters: [mqtt, http]}
    assert node == %{id: "vms", name: "vms", connected: true, signalCount: 1, staleCount: 0}
    assert %{"id" => "mqtt", "status" => %{level: :off}} = mqtt
    assert %{"id" => "http", "status" => %{level: :ok}, "port" => 4100} = http
  end

  test "pushes again only when a node or an adapter changes" do
    socket = join()
    assert_push "status", _

    send(socket.channel_pid, :check)
    refute_push "status", _

    Cache.put_all([presence(false)])
    send(socket.channel_pid, :check)
    assert_push "status", %{nodes: [%{connected: false}]}
  end
end

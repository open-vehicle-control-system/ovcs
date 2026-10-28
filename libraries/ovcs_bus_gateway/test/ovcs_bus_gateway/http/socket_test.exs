defmodule OvcsBusGateway.Http.SocketTest do
  use ExUnit.Case, async: false

  alias OvcsBusGateway.{Cache, Envelope, Subscribers}
  alias OvcsBusGateway.Http.Socket

  setup do
    start_supervised!(Subscribers)
    start_supervised!(Cache)
    Cache.put_all([env("vms", "speed"), env("ros", "yaw")])
    :ok
  end

  defp env(node, name) do
    %Envelope{node: node, source: "A", name: name, value: 1, changed_at: 0, published_at: 5}
  end

  test "sends a snapshot on connect" do
    assert {:push, {:text, json}, _} = Socket.init(%{node: "vms"})
    assert %{"type" => "snapshot", "signals" => [%{"node" => "vms"}]} = Jason.decode!(json)
  end

  test "subscribes to the bus on connect" do
    Socket.init(%{})
    Subscribers.dispatch([env("vms", "gear")])

    assert_receive {:ovcs_bus_gateway, [%{name: "gear"}]}
  end

  test "pushes only the envelopes matching its filter" do
    state = %{node: "vms"}
    message = {:ovcs_bus_gateway, [env("vms", "gear"), env("ros", "yaw")]}

    assert {:push, {:text, json}, ^state} = Socket.handle_info(message, state)

    assert %{"type" => "update", "signals" => [%{"name" => "gear", "published_at" => 5}]} =
             Jason.decode!(json)
  end

  test "pushes nothing when no envelope matches" do
    state = %{node: "vms"}
    assert {:ok, ^state} = Socket.handle_info({:ovcs_bus_gateway, [env("ros", "yaw")]}, state)
  end

  test "closes a client that falls behind" do
    for _ <- 1..1_001, do: send(self(), :noise)

    assert {:stop, :normal, {1013, "falling behind"}, _} =
             Socket.handle_info({:ovcs_bus_gateway, [env("vms", "gear")]}, %{})
  end

  test "schedules a ping on connect and reschedules it after each ping" do
    Application.put_env(:ovcs_bus_gateway, :ping_interval, 5)
    on_exit(fn -> Application.delete_env(:ovcs_bus_gateway, :ping_interval) end)

    Socket.init(%{})
    assert_receive :ping

    assert {:push, {:ping, ""}, %{}} = Socket.handle_info(:ping, %{})
    assert_receive :ping
  end

  test "ignores unrelated messages" do
    assert {:ok, %{}} = Socket.handle_info(:other, %{})
  end
end

defmodule OvcsBusGateway.Http.SignalsChannelTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  alias OvcsBusGateway.{Cache, Envelope, Subscribers}
  alias OvcsBusGateway.Http.{Endpoint, SignalsChannel, Socket}

  @endpoint Endpoint

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:phoenix)
    :ok
  end

  setup do
    start_supervised!(Subscribers)
    start_supervised!(Cache)
    start_supervised!({Phoenix.PubSub, name: OvcsBusGateway.PubSub})
    start_supervised!({Endpoint, server: false, pubsub_server: OvcsBusGateway.PubSub})
    Cache.put_all([envelope("vms", "speed"), envelope("ros", "yaw")])
    :ok
  end

  defp envelope(node, name) do
    %Envelope{node: node, source: "A", name: name, value: 1, changed_at: 0, published_at: 5}
  end

  defp join(params) do
    {:ok, _reply, socket} =
      Socket |> socket() |> subscribe_and_join(SignalsChannel, "signals", params)

    socket
  end

  test "pushes the cached envelopes matching the filter after the join" do
    join(%{"node" => "vms"})

    assert_push "snapshot", %{signals: [%Envelope{node: "vms", name: "speed"}]}
  end

  test "ignores empty filter params" do
    join(%{"node" => "", "source" => ""})

    assert_push "snapshot", %{signals: [_, _]}
  end

  test "pushes only the envelopes matching its filter" do
    join(%{"node" => "vms"})
    assert_push "snapshot", _

    Subscribers.dispatch([envelope("vms", "gear"), envelope("ros", "yaw")])

    assert_push "update", %{signals: [%Envelope{name: "gear", published_at: 5}]}
  end

  test "pushes nothing when no envelope matches" do
    join(%{"node" => "vms"})
    assert_push "snapshot", _

    Subscribers.dispatch([envelope("ros", "yaw")])

    refute_push "update", _
  end

  test "stops when its client falls behind" do
    socket = join(%{})
    assert_push "snapshot", _
    channel = Process.monitor(socket.channel_pid)
    # The test process is the socket's transport.
    for _ <- 1..1_001, do: send(self(), :noise)

    Subscribers.dispatch([envelope("vms", "gear")])

    assert_push "overloaded", %{}
    assert_receive {:DOWN, ^channel, :process, _pid, :normal}
    refute_received %Phoenix.Socket.Message{event: "update"}
  end

  test "ignores unrelated messages" do
    socket = join(%{})
    assert {:noreply, ^socket} = SignalsChannel.handle_info(:other, socket)
  end
end

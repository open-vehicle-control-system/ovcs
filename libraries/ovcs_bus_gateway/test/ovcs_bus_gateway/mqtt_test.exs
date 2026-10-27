defmodule OvcsBusGateway.MqttTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias OvcsBusGateway.{Cache, Envelope, Mqtt, Subscribers}

  setup do
    start_supervised!(Subscribers)
    start_supervised!(Cache)
    :ok
  end

  defp env(source, name, value),
    do: %Envelope{node: "vms", source: source, name: name, value: value, timestamp: 0}

  defp start_mqtt(opts) do
    start_supervised!(
      {Mqtt,
       Keyword.merge(
         [vehicle: OvcsMini, client_id: client_id(), host: "127.0.0.1", port: 1883],
         opts
       )}
    )
  end

  defp idle_connection(test_pid) do
    fn _client, _host, _port ->
      pid =
        spawn_link(fn ->
          receive do
            :stop -> :ok
          end
        end)

      send(test_pid, {:connected, pid})
      {:ok, pid}
    end
  end

  test "topic" do
    assert Mqtt.topic("ovcs_mini", env("VmsCore.Vehicle", "speed", 1)) ==
             "ovcs/ovcs_mini/vms/VmsCore.Vehicle/speed"
  end

  defp client_id, do: "ovcs_bus_gateway_test"

  defp up(pid), do: send(pid, {{Tortoise311, client_id()}, :status, :up})
  defp down(pid), do: send(pid, {{Tortoise311, client_id()}, :status, :down})

  test "publishes each envelope retained as JSON without waiting" do
    test_pid = self()

    pid =
      start_mqtt(
        connect: idle_connection(test_pid),
        publish: fn client, topic, payload, opts ->
          send(test_pid, {:pub, client, topic, payload, opts})
          :ok
        end
      )

    up(pid)
    Subscribers.dispatch([env("A", "speed", 1)])

    client_id = client_id()
    assert_receive {:pub, ^client_id, "ovcs/ovcs_mini/vms/A/speed", payload, opts}

    assert %{"value" => 1} = Jason.decode!(payload)
    assert opts[:retain] == true
    assert opts[:qos] == 0
    assert opts[:timeout] == 0
  end

  test "publishes the cached envelopes, retained, each time the connection comes up" do
    test_pid = self()
    Cache.put_all([env("A", "speed", 1), env("B", "ready", true)])

    pid =
      start_mqtt(
        connect: idle_connection(test_pid),
        publish: fn _client, topic, _payload, opts ->
          send(test_pid, {:pub, topic, opts[:retain]})
          :ok
        end
      )

    up(pid)
    assert_receive {:pub, "ovcs/ovcs_mini/gateway/online", true}
    assert_receive {:pub, "ovcs/ovcs_mini/vms/A/speed", true}
    assert_receive {:pub, "ovcs/ovcs_mini/vms/B/ready", true}

    up(pid)
    :sys.get_state(pid)
    refute_received {:pub, _, _}

    down(pid)
    up(pid)
    assert_receive {:pub, "ovcs/ovcs_mini/vms/A/speed", true}
    assert_receive {:pub, "ovcs/ovcs_mini/vms/B/ready", true}
  end

  test "survives a failing publish" do
    test_pid = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    pid =
      start_mqtt(
        connect: idle_connection(test_pid),
        publish: fn client, topic, payload, opts ->
          case Agent.get_and_update(calls, &{&1, &1 + 1}) do
            0 -> raise "closed"
            1 -> exit(:noproc)
            2 -> {:error, :unknown_connection}
            _ -> send(test_pid, {:pub, client, topic, payload, opts})
          end
        end
      )

    up(pid)
    for name <- ~w(a b c d), do: Subscribers.dispatch([env("A", name, 1)])

    assert_receive {:pub, _, "ovcs/ovcs_mini/vms/A/d", _, _}
    assert Process.alive?(pid)
  end

  test "skips an envelope it cannot encode, live or from the cache" do
    test_pid = self()
    unencodable = %{env("A", "bad", 1) | unit: {:not, :json}}
    Cache.put_all([unencodable])

    pid =
      start_mqtt(
        connect: idle_connection(test_pid),
        publish: fn _client, topic, _payload, _opts ->
          send(test_pid, {:pub, topic})
          :ok
        end
      )

    up(pid)
    assert_receive {:pub, "ovcs/ovcs_mini/gateway/online"}
    Subscribers.dispatch([unencodable, env("A", "good", 1)])

    assert_receive {:pub, "ovcs/ovcs_mini/vms/A/good"}
    refute_received {:pub, "ovcs/ovcs_mini/vms/A/bad"}
    assert Process.alive?(pid)
  end

  test "does not publish while the connection is not up" do
    test_pid = self()

    pid =
      start_mqtt(
        connect: idle_connection(test_pid),
        publish: fn _client, topic, _payload, _opts ->
          send(test_pid, {:pub, topic})
          :ok
        end
      )

    Subscribers.dispatch([env("A", "speed", 1)])
    :sys.get_state(pid)
    refute_received {:pub, _}

    up(pid)
    assert_receive {:pub, "ovcs/ovcs_mini/gateway/online"}
    Subscribers.dispatch([env("A", "speed", 2)])
    assert_receive {:pub, "ovcs/ovcs_mini/vms/A/speed"}

    down(pid)
    Subscribers.dispatch([env("A", "speed", 3)])
    :sys.get_state(pid)
    refute_received {:pub, _}
  end

  test "replaces a connection that exits abnormally after the reconnect interval" do
    pid = start_mqtt(connect: idle_connection(self()), reconnect_interval: 50)

    assert_receive {:connected, first}
    Process.exit(first, :ehostunreach)

    assert_receive {:connected, second}, 1_000
    assert second != first
    assert Process.alive?(pid)
  end

  test "retries a connection that fails to start" do
    test_pid = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    connect = fn client, host, port ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> {:error, :econnrefused}
        _ -> idle_connection(test_pid).(client, host, port)
      end
    end

    start_mqtt(connect: connect, reconnect_interval: 50)
    assert_receive {:connected, _}, 1_000
  end

  test "a broker nothing listens on neither blocks nor crashes the publisher" do
    {:ok, _} = Application.ensure_all_started(:tortoise311)

    {:ok, listener} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listener)
    :gen_tcp.close(listener)

    pid = start_mqtt(port: port, reconnect_interval: 100)
    Process.sleep(100)

    started = System.monotonic_time(:millisecond)
    Subscribers.dispatch([env("A", "speed", 1)])
    :sys.get_state(pid, 200)
    assert System.monotonic_time(:millisecond) - started < 200

    assert Process.alive?(pid)
  end

  test "publishes the gateway as online, retained, before the cache on each connection" do
    test_pid = self()
    Cache.put_all([env("A", "speed", 1)])

    pid =
      start_mqtt(
        connect: idle_connection(test_pid),
        publish: fn _client, topic, payload, opts ->
          send(test_pid, {:pub, topic, payload, opts[:retain]})
          :ok
        end
      )

    up(pid)
    assert_receive {:pub, topic, payload, retain}
    assert {topic, payload, retain} == {"ovcs/ovcs_mini/gateway/online", "true", true}
    assert_receive {:pub, "ovcs/ovcs_mini/vms/A/speed", _, true}

    down(pid)
    up(pid)
    assert_receive {:pub, "ovcs/ovcs_mini/gateway/online", "true", true}
  end

  test "drops batches while its mailbox is over the queue limit" do
    test_pid = self()

    pid =
      start_mqtt(
        connect: idle_connection(test_pid),
        max_queue: 2,
        publish: fn _client, topic, _payload, _opts ->
          send(test_pid, {:pub, topic})
          :ok
        end
      )

    up(pid)
    assert_receive {:pub, "ovcs/ovcs_mini/gateway/online"}

    :sys.suspend(pid)
    for name <- ~w(a b c d e), do: Subscribers.dispatch([env("A", name, 1)])
    :sys.resume(pid)
    :sys.get_state(pid)

    published = for name <- ~w(a b c d e), received_pub?("ovcs/ovcs_mini/vms/A/#{name}"), do: name
    assert "a" not in published
    assert "b" not in published
    assert "d" in published
    assert "e" in published
  end

  defp received_pub?(topic) do
    receive do
      {:pub, ^topic} -> true
    after
      0 -> false
    end
  end

  test "warns once when the connection is lost, then logs at debug until it is up again" do
    log =
      capture_log([level: :debug], fn ->
        pid = start_mqtt(connect: idle_connection(self()), reconnect_interval: 20)

        assert_receive {:connected, first}
        Process.exit(first, :ehostunreach)
        assert_receive {:connected, second}, 1_000
        Process.exit(second, :ehostunreach)
        assert_receive {:connected, third}, 1_000

        up(pid)
        :sys.get_state(pid)
        Process.exit(third, :ehostunreach)
        assert_receive {:connected, _fourth}, 1_000
      end)

    assert occurrences(log, "[warning] MQTT connection") == 2
    assert occurrences(log, "[debug] MQTT connection") == 1
  end

  defp occurrences(log, text), do: length(String.split(log, text)) - 1

  describe "with the tortoise311 application stopped" do
    setup do
      Application.stop(:tortoise311)
      on_exit(fn -> {:ok, _} = Application.ensure_all_started(:tortoise311) end)
    end

    test "the default connection reports an error instead of crashing" do
      log =
        capture_log(fn ->
          pid = start_mqtt(reconnect_interval: 20)
          Process.sleep(100)
          assert Process.alive?(pid)
        end)

      assert log =~ "MQTT connection to 127.0.0.1"
    end
  end

  test "connects with a retained offline will and bounded, unbuffered socket options" do
    {:ok, _} = Application.ensure_all_started(:tortoise311)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    test_pid = self()

    broker =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)
        {:ok, connect} = :gen_tcp.recv(socket, 0, 2_000)
        send(test_pid, {:connect_packet, connect})
        :ok = :gen_tcp.send(socket, <<0x20, 0x02, 0x00, 0x00>>)

        receive do
          :stop -> :gen_tcp.close(socket)
        end
      end)

    pid = start_mqtt(port: port)
    assert_receive {:connect_packet, packet}, 2_000

    # Connect flags: will retain (0x20) and will (0x04).
    [_, <<4, flags, _rest::binary>>] = :binary.split(packet, <<0, 4, "MQTT">>)
    assert Bitwise.band(flags, 0x24) == 0x24
    assert packet =~ "ovcs/ovcs_mini/gateway/online"
    assert String.ends_with?(packet, <<0, 5, "false">>)

    await_up(pid)
    {:ok, {_transport, socket}} = Tortoise311.Connection.connection(client_id())

    assert {:ok, opts} = :inet.getopts(socket, [:nodelay, :send_timeout, :send_timeout_close])
    assert opts[:nodelay] == true
    assert opts[:send_timeout] == 1_000
    assert opts[:send_timeout_close] == true

    stop_supervised!(Mqtt)
    send(broker.pid, :stop)
    Task.await(broker)
    :gen_tcp.close(listener)
  end

  defp await_up(pid, attempts \\ 200) do
    cond do
      :sys.get_state(pid).up? ->
        :ok

      attempts == 0 ->
        flunk("MQTT connection not up")

      true ->
        Process.sleep(10)
        await_up(pid, attempts - 1)
    end
  end
end

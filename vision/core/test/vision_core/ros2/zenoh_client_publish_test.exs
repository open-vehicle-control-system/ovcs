defmodule VisionCore.Ros2.ZenohClientPublishTest do
  @moduledoc """
  A message is encoded by the process that publishes it, never by the shared
  client: a raise in the client restarts the cameras behind it (the unit's
  supervisor is `:rest_for_one`), where a raise in the publisher costs one message.
  While the client has no session nothing is encoded at all.

  The put is exercised on a local Zenoh session, which needs no router: the
  client's own `handle_cast/2` runs on a state holding that session, or the
  client runs with that session as the one it opens, and a subscriber on the
  same session reads what reaches the wire.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ros2Zenoh.RmwZenoh
  alias Ros2Zenoh.StdMsgs.Msg.Float64
  alias Ros2Zenoh.StdMsgs.Msg.String, as: StringMessage
  alias VisionCore.Ros2.{Topics, ZenohClient}
  alias VisionCore.Ros2.ZenohClient.State

  @moduletag :capture_log

  @topic "ovcs_heartbeat"

  # Stands in for the client process: hands every publish request to the test.
  defmodule Client do
    use GenServer

    def start_link(test),
      do: GenServer.start_link(__MODULE__, test, name: VisionCore.Ros2.ZenohClient)

    @impl GenServer
    def init(test), do: {:ok, test}

    @impl GenServer
    def handle_cast({:publish, _topic, _module, _message, _payload, _opts} = request, test) do
      send(test, request)
      {:noreply, test}
    end
  end

  # Reports each encode, with the process that ran it, to the test.
  defmodule Probe do
    defstruct [:test]

    def dds_type, do: "std_msgs::msg::dds_::Probe_"
    def type_hash, do: "RIHS01_probe"

    def encode(%__MODULE__{test: test}) do
      send(test, {:encoded_in, self()})
      "body"
    end
  end

  defp unencodable, do: %StringMessage{data: nil}

  defp occurrences(log, text), do: length(String.split(log, text)) - 1

  setup do
    %{topics: start_supervised!(Topics)}
  end

  defp start_fake_client(_context) do
    start_supervised!({Client, self()})
    :ok
  end

  defp tick(topics) do
    send(topics, :tick)
    :sys.get_state(topics)
  end

  # A Zenoh session with a subscriber on it, which needs no router.
  defp local_session do
    config =
      Zenohex.Config.default()
      |> Zenohex.Config.update_in(["mode"], fn _ -> "peer" end)
      |> Zenohex.Config.update_in(["scouting", "multicast", "enabled"], fn _ -> false end)
      |> Zenohex.Config.update_in(["listen", "endpoints"], fn _ -> [] end)

    {:ok, session} = Zenohex.Session.open(config)

    {:ok, subscriber} =
      Zenohex.Session.declare_subscriber(session, "0/#{@topic}/**", self(), [])

    # The closure keeps both handles alive: a handle that is collected undeclares itself.
    on_exit(fn ->
      Zenohex.Subscriber.undeclare(subscriber)
      Zenohex.Session.close(session)
    end)

    session
  end

  # How a client opens its session: each result in turn, then no router.
  defp opener(results) do
    agent = start_supervised!({Agent, fn -> results end})

    fn _endpoint_ip ->
      Agent.get_and_update(agent, fn
        [next | rest] -> {next, rest}
        [] -> {{:error, :unreachable}, []}
      end)
    end
  end

  defp received_put do
    assert_receive %Zenohex.Sample{payload: payload, attachment: attachment}, 1_000

    assert <<sequence_number::little-signed-64, _stamp::binary-size(8), 16, gid::binary-size(16)>> =
             attachment

    {sequence_number, gid, payload}
  end

  # The session hands samples over from its own threads, in no fixed order.
  defp received_puts(count),
    do: Enum.sort(Enum.map(1..count, fn _put -> received_put() end))

  describe "a message that cannot be encoded" do
    setup :start_fake_client

    test "is refused with an error, and never reaches the client" do
      assert {:error, {:encode_raised, reason}} =
               ZenohClient.publish(@topic, StringMessage, unencodable())

      assert reason =~ "encode_string"

      assert {:error, {:encode_raised, _reason}} =
               ZenohClient.publish(@topic, StringMessage, %{data: "not a struct"})

      refute_receive {:publish, _topic, _module, _message, _payload, _opts}
    end

    test "is counted under its topic, apart from the publishes", %{topics: topics} do
      for _ <- 1..2, do: ZenohClient.publish(@topic, StringMessage, unencodable())
      tick(topics)

      assert [
               %{
                 name: "/ovcs_heartbeat",
                 type: "std_msgs/msg/String",
                 rate_hz: +0.0,
                 encode_failures: 2
               }
             ] = Topics.topics()

      :ok = ZenohClient.publish(@topic, StringMessage, %StringMessage{data: "alive"})
      tick(topics)

      assert [%{rate_hz: rate_hz, encode_failures: 2}] = Topics.topics()
      assert rate_hz > 0
    end

    test "is logged once per topic and message type" do
      log =
        capture_log(fn ->
          for _ <- 1..3, do: ZenohClient.publish(@topic, StringMessage, unencodable())
        end)

      assert occurrences(log, "cannot encode") == 1
      assert log =~ "Ros2Zenoh.StdMsgs.Msg.String"
      assert log =~ @topic

      other_topic =
        capture_log(fn -> ZenohClient.publish("other", StringMessage, unencodable()) end)

      assert occurrences(other_topic, "cannot encode") == 1
      assert other_topic =~ "other"

      other_type =
        capture_log(fn -> ZenohClient.publish(@topic, Float64, %Float64{data: nil}) end)

      assert occurrences(other_type, "cannot encode") == 1
      assert other_type =~ "Ros2Zenoh.StdMsgs.Msg.Float64"

      repeated = capture_log(fn -> ZenohClient.publish(@topic, StringMessage, unencodable()) end)
      assert occurrences(repeated, "cannot encode") == 0
    end
  end

  describe "a message that encodes" do
    setup :start_fake_client

    test "reaches the client with the payload its publisher encoded" do
      message = %StringMessage{data: "alive"}

      assert :ok = ZenohClient.publish(@topic, StringMessage, message)

      assert_receive {:publish, @topic, StringMessage, ^message, payload, []}
      assert payload == RmwZenoh.encode_payload(message)
    end

    test "is counted as a publish", %{topics: topics} do
      :ok = ZenohClient.publish(@topic, StringMessage, %StringMessage{data: "alive"})
      tick(topics)

      assert [%{name: "/ovcs_heartbeat", rate_hz: rate_hz, encode_failures: 0}] = Topics.topics()
      assert rate_hz > 0
    end
  end

  describe "the client" do
    setup :start_fake_client

    setup do
      %{state: %State{session: local_session(), domain_id: 0, node_name: "vision_test"}}
    end

    defp hand_over_next_request(state) do
      assert_receive {:publish, _topic, _module, _message, _payload, _opts} = request
      assert {:noreply, state} = ZenohClient.handle_cast(request, state)
      state
    end

    test "puts the payload it was handed, never encoding it itself", %{state: state} do
      test = self()

      caller_pid =
        Task.await(
          Task.async(fn ->
            :ok = ZenohClient.publish(@topic, Probe, %Probe{test: test})
            self()
          end)
        )

      assert_receive {:encoded_in, ^caller_pid}

      hand_over_next_request(state)

      assert {1, _gid, <<0, 1, 0, 0, "body">>} = received_put()
      refute_receive {:encoded_in, _process}
    end

    test "numbers the puts of a topic in order, under one publisher identity", %{state: state} do
      message = %StringMessage{data: "alive"}

      state =
        Enum.reduce(1..3, state, fn _put, state ->
          :ok = ZenohClient.publish(@topic, StringMessage, message)
          hand_over_next_request(state)
        end)

      assert [{1, gid, _payload}, {2, second_gid, _}, {3, third_gid, _}] = received_puts(3)
      assert gid == second_gid and gid == third_gid
      assert state.publishers[@topic].sequence_number == 3
    end

    test "does not skip a number for a message that could not be encoded", %{state: state} do
      valid = %StringMessage{data: "alive"}

      :ok = ZenohClient.publish(@topic, StringMessage, valid)
      {:error, _reason} = ZenohClient.publish(@topic, StringMessage, unencodable())
      :ok = ZenohClient.publish(@topic, StringMessage, valid)

      state = state |> hand_over_next_request() |> hand_over_next_request()
      refute_receive {:publish, _topic, _module, _message, _payload, _opts}

      assert [{1, _gid, _payload}, {2, _, _}] = received_puts(2)
      assert state.publishers[@topic].sequence_number == 2
    end

    test "drops a publish without payload, which its caller sent while it had no session",
         %{state: state} do
      request = {:publish, @topic, StringMessage, %StringMessage{data: "alive"}, nil, []}

      assert {:noreply, %State{drops_while_offline: 1, publishers: publishers}} =
               ZenohClient.handle_cast(request, state)

      assert publishers == %{}
      refute_receive %Zenohex.Sample{}
    end
  end

  describe "the client without a session" do
    setup :start_fake_client

    test "drops a publish and counts the drop" do
      :ok = ZenohClient.publish(@topic, StringMessage, %StringMessage{data: "alive"})
      assert_receive {:publish, _topic, _module, _message, _payload, _opts} = request

      assert {:noreply, %State{drops_while_offline: 1, publishers: publishers}} =
               ZenohClient.handle_cast(request, %State{})

      assert publishers == %{}
    end
  end

  describe "a running client" do
    test "drops a publish and counts it without encoding while it has no session",
         %{topics: topics} do
      start_supervised!({ZenohClient, endpoint_ip: "127.0.0.1", open_session: opener([])})
      refute ZenohClient.connected?()

      assert :ok = ZenohClient.publish(@topic, Probe, %Probe{test: self()})
      assert :ok = ZenohClient.publish(@topic, StringMessage, unencodable())

      refute_receive {:encoded_in, _process}
      assert %State{drops_while_offline: 2} = :sys.get_state(ZenohClient)

      tick(topics)
      assert [%{name: "/ovcs_heartbeat", rate_hz: rate_hz, encode_failures: 0}] = Topics.topics()
      assert rate_hz > 0
    end

    test "encodes once its session opens, and no more once the session is lost" do
      test = self()
      session = local_session()

      client =
        start_supervised!(
          {ZenohClient,
           endpoint_ip: "127.0.0.1",
           node_name: "vision_test",
           open_session: opener([{:error, :unreachable}, {:ok, session}])}
        )

      refute ZenohClient.connected?()
      :ok = ZenohClient.publish(@topic, Probe, %Probe{test: test})
      refute_receive {:encoded_in, _process}

      # What the reconnect timer sends.
      send(client, {:connect, 1_000})
      assert ZenohClient.connected?()

      :ok = ZenohClient.publish(@topic, Probe, %Probe{test: test})
      assert_receive {:encoded_in, ^test}
      assert {1, _gid, <<0, 1, 0, 0, "body">>} = received_put()

      # The client learns of the loss from a put, which it cannot make; that message is lost.
      Zenohex.Session.close(session)
      :ok = ZenohClient.publish(@topic, Probe, %Probe{test: test})
      assert_receive {:encoded_in, ^test}
      refute ZenohClient.connected?()

      :ok = ZenohClient.publish(@topic, Probe, %Probe{test: test})
      refute_receive {:encoded_in, _process}
      assert %State{drops_while_offline: 1} = :sys.get_state(ZenohClient)
    end
  end
end

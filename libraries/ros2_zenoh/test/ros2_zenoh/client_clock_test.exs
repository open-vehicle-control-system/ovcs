defmodule Ros2Zenoh.ClientClockTest do
  @moduledoc """
  Nothing is encoded or published before the board's clock is synchronized.

  A board without a real-time clock boots on a time far in the past until
  NTP corrects it. A message stamped then reaches its consumers days before
  the transforms and the other topics they compare it with: Nav2's
  `RangeSensorLayer` blocks on each such reading until its transform
  tolerance runs out, falls further behind with every reading that follows,
  and its costmaps stop publishing until Nav2 restarts.

  The client runs with a local Zenoh session as the one it opens, which
  needs no router, and a subscriber on that session reads what reaches the
  wire.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ros2Zenoh.Client
  alias Ros2Zenoh.Client.State

  @moduletag :capture_log

  @topic "ovcs_clock_test"

  # Reports each encode to the test.
  defmodule Probe do
    defstruct [:test]

    def dds_type, do: "std_msgs::msg::dds_::Probe_"
    def type_hash, do: "RIHS01_probe"

    def encode(%__MODULE__{test: test}) do
      send(test, :encoded)
      "body"
    end
  end

  # The clock's synchronization, as a test flips it.
  def synchronized?(agent), do: Agent.get(agent, & &1)

  def raising_check, do: raise("NervesTime is not running")

  # The OS clock, `ahead_ms` (as a test sets it) past the BEAM's.
  def os_time(agent), do: System.system_time(:millisecond) + Agent.get(agent, & &1)

  defp clock(synchronized) do
    agent = start_supervised!({Agent, fn -> synchronized end}, id: :clock)
    {agent, {__MODULE__, :synchronized?, [agent]}}
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

  # The client opens its session in a task of its own.
  defp await_connected(attempts \\ 150) do
    cond do
      Client.link().connected ->
        :ok

      attempts == 0 ->
        flunk("the client did not connect")

      true ->
        Process.sleep(20)
        await_connected(attempts - 1)
    end
  end

  defp start_client(check, opts \\ []) do
    session = local_session()

    client =
      start_supervised!(
        {Client,
         [
           endpoint_ip: "127.0.0.1",
           node_name: "ros2_zenoh_test",
           open_session: fn _endpoint_ip -> {:ok, session} end,
           clock_synchronized?: check
         ] ++ opts}
      )

    await_connected()
    client
  end

  defp publish, do: :ok = Client.publish(@topic, Probe, %Probe{test: self()})

  test "publishes from the start without a clock check, as on a host or against a simulator" do
    start_client(nil)

    publish()
    assert_receive :encoded
    assert_receive %Zenohex.Sample{}, 1_000
  end

  test "neither encodes nor publishes while the clock is not synchronized" do
    {_agent, check} = clock(false)
    start_client(check)

    publish()
    publish()

    refute_receive :encoded, 300
    refute_receive %Zenohex.Sample{}

    assert %State{clock_synchronized: false, drops_before_clock_sync: 2} =
             :sys.get_state(Client)
  end

  test "publishes once the clock is synchronized, and says how much it dropped" do
    {agent, check} = clock(false)
    client = start_client(check)
    publish()
    refute_receive :encoded, 300

    Agent.update(agent, fn _ -> true end)

    log =
      capture_log(fn ->
        # What the clock timer sends.
        send(client, :check_clock)
        assert %State{clock_synchronized: true} = :sys.get_state(Client)
      end)

    assert log =~ "clock synchronized"
    assert log =~ "dropped 1"

    publish()
    assert_receive :encoded
    assert_receive %Zenohex.Sample{}, 1_000
  end

  test "waits for the BEAM's clock to follow the OS clock NTP stepped" do
    {_agent, check} = clock(true)
    thirteen_days_ms = 13 * 24 * 3_600_000
    os_clock = start_supervised!({Agent, fn -> thirteen_days_ms end}, id: :os_clock)
    client = start_client(check, os_clock: {__MODULE__, :os_time, [os_clock]})

    publish()
    refute_receive :encoded, 300
    assert %State{clock_synchronized: false} = :sys.get_state(Client)

    Agent.update(os_clock, fn _ -> 0 end)
    send(client, :check_clock)
    assert %State{clock_synchronized: true} = :sys.get_state(Client)

    publish()
    assert_receive :encoded
    assert_receive %Zenohex.Sample{}, 1_000
  end

  test "checks the clock again while it is not synchronized" do
    {_agent, check} = clock(false)
    client = start_client(check)

    :erlang.trace(client, true, [:receive])
    assert_receive {:trace, ^client, :receive, :check_clock}, 2_500
  end

  test "takes a check that raises for an unsynchronized clock" do
    start_client({__MODULE__, :raising_check, []})

    publish()
    refute_receive :encoded, 300
    assert %State{clock_synchronized: false} = :sys.get_state(Client)
  end

  test "keeps its subscriptions while the clock is not synchronized" do
    {_agent, check} = clock(false)
    start_client(check)

    assert :ok = Client.subscribe(@topic, Ros2Zenoh.StdMsgs.Msg.String)
    assert %State{subscriptions: subscriptions} = :sys.get_state(Client)
    assert [%{subscriber_id: subscriber_id}] = Map.values(subscriptions)
    refute is_nil(subscriber_id)
  end
end

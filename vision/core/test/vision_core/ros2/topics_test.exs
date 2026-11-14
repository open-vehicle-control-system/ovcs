defmodule VisionCore.Ros2.TopicsTest do
  use ExUnit.Case, async: false

  alias Ros2Zenoh.Client
  alias Ros2Zenoh.SensorMsgs.Msg.{CameraInfo, CompressedImage}
  alias Ros2Zenoh.StdMsgs.Msg.String, as: StringMessage
  alias VisionCore.Ros2.Topics

  setup do
    pid = start_supervised!(Topics)
    %{topics: pid}
  end

  defp tick(pid) do
    send(pid, :tick)
    :sys.get_state(pid)
  end

  test "lists no topic before any publish" do
    assert Topics.topics() == []
  end

  test "lists each counted topic by its full name and ROS type, sorted by name", %{topics: pid} do
    Topics.count("stereo/left/image_raw/compressed", CompressedImage)
    Topics.count("/stereo/left/camera_info", CameraInfo)
    tick(pid)

    assert [
             %{name: "/stereo/left/camera_info", type: "sensor_msgs/msg/CameraInfo"},
             %{
               name: "/stereo/left/image_raw/compressed",
               type: "sensor_msgs/msg/CompressedImage"
             }
           ] = Topics.topics()
  end

  test "turns the counts of each tick into a rate per second", %{topics: pid} do
    for _ <- 1..3, do: Topics.count("stereo/depth/camera_info", CameraInfo)
    tick(pid)
    [%{rate_hz: first}] = Topics.topics()
    assert first > 0

    tick(pid)
    assert [%{rate_hz: +0.0}] = Topics.topics()
  end

  test "names a module without a DDS type by its module name", %{topics: pid} do
    Topics.count("plain", String)
    tick(pid)

    assert [%{name: "/plain", type: "String"}] = Topics.topics()
  end

  test "lists no encode failure for a topic that has none", %{topics: pid} do
    Topics.count("stereo/depth/camera_info", CameraInfo)
    tick(pid)

    assert [%{name: "/stereo/depth/camera_info", encode_failures: 0}] = Topics.topics()
  end

  test "counts the messages that could not be encoded apart from the publishes", %{topics: pid} do
    Topics.count("stereo/points", CameraInfo)
    Topics.count_encode_failure("stereo/points", CameraInfo)
    Topics.count_encode_failure("/stereo/points", CameraInfo)
    tick(pid)

    assert [%{name: "/stereo/points", encode_failures: 2}] = Topics.topics()

    tick(pid)
    assert [%{name: "/stereo/points", rate_hz: +0.0, encode_failures: 2}] = Topics.topics()
  end

  test "lists a topic whose every message failed, at no rate", %{topics: pid} do
    assert Topics.count_encode_failure("stereo/points", CameraInfo) == :ok
    tick(pid)

    assert [
             %{
               name: "/stereo/points",
               type: "sensor_msgs/msg/CameraInfo",
               rate_hz: +0.0,
               encode_failures: 1
             }
           ] = Topics.topics()
  end

  test "counting without the table running is a no-op" do
    stop_supervised!(Topics)

    assert Topics.count("stereo/points", CameraInfo) == :ok
    assert Topics.count_encode_failure("stereo/points", CameraInfo) == :ok
    assert Topics.topics() == []
  end

  # A Zenoh session that needs no router.
  defp local_session do
    config =
      Zenohex.Config.default()
      |> Zenohex.Config.update_in(["mode"], fn _ -> "peer" end)
      |> Zenohex.Config.update_in(["scouting", "multicast", "enabled"], fn _ -> false end)
      |> Zenohex.Config.update_in(["listen", "endpoints"], fn _ -> [] end)

    {:ok, session} = Zenohex.Session.open(config)
    on_exit(fn -> Zenohex.Session.close(session) end)
    session
  end

  defp start_client(options) do
    start_supervised!({Client, [endpoint_ip: "127.0.0.1", node_name: "vision_test"] ++ options})
  end

  # The client opens its session in a task of its own.
  defp await_session(attempts \\ 150) do
    cond do
      Client.session_open?() -> :ok
      attempts == 0 -> flunk("the client did not open its session")
      true -> Process.sleep(20) && await_session(attempts - 1)
    end
  end

  def clock_not_synchronized, do: false

  describe "publish/4 while the client drops what it is given" do
    @describetag :capture_log

    test "lists a topic at no rate while the clock is not synchronized", %{topics: pid} do
      session = local_session()

      start_client(
        open_session: fn _endpoint_ip -> {:ok, session} end,
        clock_synchronized?: {__MODULE__, :clock_not_synchronized, []}
      )

      await_session()

      assert :ok = Topics.publish("ovcs_heartbeat", StringMessage, %StringMessage{data: "alive"})
      tick(pid)

      assert [%{name: "/ovcs_heartbeat", type: "std_msgs/msg/String", rate_hz: +0.0}] =
               Topics.topics()
    end

    test "lists a topic at no rate while the client has no session", %{topics: pid} do
      start_client(open_session: fn _endpoint_ip -> Process.sleep(:infinity) end)

      assert :ok = Topics.publish("ovcs_heartbeat", StringMessage, %StringMessage{data: "alive"})
      tick(pid)

      assert [%{name: "/ovcs_heartbeat", rate_hz: +0.0}] = Topics.topics()
    end
  end

  describe "publish/4" do
    @describetag :capture_log

    setup do
      session = local_session()
      start_client(open_session: fn _endpoint_ip -> {:ok, session} end)
      await_session()
    end

    test "counts a message the client takes as a publish", %{topics: pid} do
      assert :ok = Topics.publish("ovcs_heartbeat", StringMessage, %StringMessage{data: "alive"})
      tick(pid)

      assert [
               %{
                 name: "/ovcs_heartbeat",
                 type: "std_msgs/msg/String",
                 rate_hz: rate_hz,
                 encode_failures: 0
               }
             ] =
               Topics.topics()

      assert rate_hz > 0
    end

    test "counts a message that cannot be encoded apart from the publishes", %{topics: pid} do
      for _ <- 1..2 do
        assert {:error, {:encode_raised, _reason}} =
                 Topics.publish("ovcs_heartbeat", StringMessage, %StringMessage{data: nil})
      end

      tick(pid)
      assert [%{rate_hz: +0.0, encode_failures: 2}] = Topics.topics()

      :ok = Topics.publish("ovcs_heartbeat", StringMessage, %StringMessage{data: "alive"})
      tick(pid)

      assert [%{rate_hz: rate_hz, encode_failures: 2}] = Topics.topics()
      assert rate_hz > 0
    end
  end
end

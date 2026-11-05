defmodule Ros2Zenoh.ClientPriorityTest do
  @moduledoc """
  Images and point clouds go out below every other message, so a router
  short of bandwidth to a subscriber sends it the transforms, the odometry
  and the commands before a frame.

  The client runs with a local Zenoh session as the one it opens, which
  needs no router, and a subscriber on that session reads the samples'
  priority off the wire.
  """
  use ExUnit.Case, async: false

  alias Ros2Zenoh.BuiltinInterfaces.Msg.Time
  alias Ros2Zenoh.Client
  alias Ros2Zenoh.SensorMsgs.Msg.{CompressedImage, Image, PointCloud2}
  alias Ros2Zenoh.StdMsgs.Msg.Header
  alias Ros2Zenoh.StdMsgs.Msg.String, as: StringMessage
  alias Ros2Zenoh.StereoMsgs.Msg.DisparityImage

  @moduletag :capture_log

  @header %Header{stamp: %Time{}}

  # A Zenoh session with a subscriber on every key, which needs no router.
  defp local_session do
    config =
      Zenohex.Config.default()
      |> Zenohex.Config.update_in(["mode"], fn _ -> "peer" end)
      |> Zenohex.Config.update_in(["scouting", "multicast", "enabled"], fn _ -> false end)
      |> Zenohex.Config.update_in(["listen", "endpoints"], fn _ -> [] end)

    {:ok, session} = Zenohex.Session.open(config)
    {:ok, subscriber} = Zenohex.Session.declare_subscriber(session, "0/**", self(), [])

    # The closure keeps both handles alive: a handle that is collected undeclares itself.
    on_exit(fn ->
      Zenohex.Subscriber.undeclare(subscriber)
      Zenohex.Session.close(session)
    end)

    session
  end

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

  setup do
    session = local_session()

    start_supervised!(
      {Client,
       endpoint_ip: "127.0.0.1",
       node_name: "ros2_zenoh_test",
       open_session: fn _endpoint_ip -> {:ok, session} end}
    )

    await_connected()
    :ok
  end

  defp priority_of(topic, module, message) do
    :ok = Client.publish(topic, module, message)
    assert_receive %Zenohex.Sample{key_expr: "0/" <> ^topic <> _rest, priority: priority}, 1_000
    priority
  end

  test "puts images and point clouds at :data_low" do
    image = %Image{header: @header}
    assert priority_of("priority_image", Image, image) == :data_low

    compressed = %CompressedImage{header: @header}
    assert priority_of("priority_compressed", CompressedImage, compressed) == :data_low

    cloud = %PointCloud2{header: @header, fields: []}
    assert priority_of("priority_cloud", PointCloud2, cloud) == :data_low

    disparity = %DisparityImage{header: @header, image: image}
    assert priority_of("priority_disparity", DisparityImage, disparity) == :data_low
  end

  test "puts every other message at Zenoh's default, :data" do
    assert priority_of("priority_string", StringMessage, %StringMessage{data: "hello"}) == :data
  end
end

defmodule VisionCore.PreviewTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias VisionCore.Camera.Frame
  alias VisionCore.Preview
  alias VisionCore.Stereo.Pair

  @config %VisionCore.Config{zenoh_endpoint_ip: "127.0.0.1", components: []}

  defp feed_left(sequence) do
    frame = %Frame{label: "left", width: 2, height: 2, capture_ns: sequence, jpeg: "#{sequence}"}
    GenServer.cast(Preview, {:camera_frame, frame})
  end

  defp pair(depth_m \\ nil) do
    frame = %Frame{label: "left", width: 4, height: 4, capture_ns: 0, jpeg: <<>>}
    %Pair{left_frame: frame, right_frame: %{frame | label: "right"}, depth_m: depth_m}
  end

  defp receive_and_ack_until(deadline_ms, frames) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {:vision_preview, :left, jpeg} ->
        Preview.ack(:left)
        receive_and_ack_until(deadline_ms, [jpeg | frames])
    after
      remaining_ms -> Enum.reverse(frames)
    end
  end

  test "preview caps a subscriber at max_hz" do
    start_supervised!({Preview, config: @config, max_hz: 5})
    :ok = Preview.subscribe(:left)

    Task.start_link(fn ->
      for sequence <- 1..30 do
        feed_left(sequence)
        Process.sleep(33)
      end
    end)

    frames = receive_and_ack_until(System.monotonic_time(:millisecond) + 1_000, [])

    assert length(frames) <= 6
    assert length(frames) >= 3
  end

  test "preview delivers only the latest frame to a slow subscriber" do
    start_supervised!({Preview, config: @config, max_hz: 50})
    :ok = Preview.subscribe(:left)

    feed_left(0)
    assert_receive {:vision_preview, :left, "0"}

    for sequence <- 1..10, do: feed_left(sequence)
    :sys.get_state(Preview)
    Preview.ack(:left)

    assert_receive {:vision_preview, :left, "10"}, 500
    refute_receive {:vision_preview, :left, _}, 200
  end

  test "depth is not encoded without subscribers" do
    test_pid = self()

    encode_depth = fn _pair ->
      send(test_pid, :depth_encoded)
      "depth jpeg"
    end

    start_supervised!({Preview, config: @config, depth_encoder: encode_depth})
    depth_m = Evision.Mat.zeros({4, 4}, :f32)

    GenServer.cast(Preview, {:stereo_pair, pair(depth_m)})
    refute_receive :depth_encoded, 200

    :ok = Preview.subscribe(:depth)
    GenServer.cast(Preview, {:stereo_pair, pair(depth_m)})

    assert_receive :depth_encoded, 500
    assert_receive {:vision_preview, :depth, "depth jpeg"}, 500
  end

  test "a pair without a depth map is not previewed" do
    preview = start_supervised!({Preview, config: @config})
    :ok = Preview.subscribe(:depth)

    GenServer.cast(Preview, {:stereo_pair, pair()})

    refute_receive {:vision_preview, :depth, _jpeg}, 200
    assert Process.alive?(preview)
  end

  test "a depth map that fails to encode is skipped, logged once" do
    preview = start_supervised!({Preview, config: @config, max_hz: 50})
    :ok = Preview.subscribe(:depth)
    two_channel = Evision.Mat.zeros({4, 4, 2}, :f32)

    log =
      capture_log(fn ->
        for _ <- 1..3 do
          GenServer.cast(Preview, {:stereo_pair, pair(two_channel)})
          :sys.get_state(Preview)
          Process.sleep(30)
        end

        refute_receive {:vision_preview, :depth, _jpeg}, 100
      end)

    assert Process.alive?(preview)
    assert length(String.split(log, "depth preview")) == 2

    GenServer.cast(Preview, {:stereo_pair, pair(Evision.Mat.zeros({4, 4}, :f32))})
    assert_receive {:vision_preview, :depth, <<0xFF, 0xD8, _::binary>>}, 500
  end

  test "a subscriber that dies while a frame awaits its ack is dropped" do
    start_supervised!({Preview, config: @config, max_hz: 50})
    test_pid = self()

    subscriber =
      spawn(fn ->
        :ok = Preview.subscribe(:left)
        send(test_pid, :subscribed)
        receive do: (:stop -> :ok)
      end)

    assert_receive :subscribed
    feed_left(1)
    :sys.get_state(Preview)
    send(subscriber, :stop)
    Process.sleep(50)
    feed_left(2)

    assert :sys.get_state(Preview).subscribers == %{}
  end

  test "the depth map is colourised into a JPEG" do
    depth_m = Evision.Mat.from_nx(Nx.iota({4, 4}, type: :f32))

    assert <<0xFF, 0xD8, _::binary>> = Preview.encode_depth(pair(depth_m))
  end
end

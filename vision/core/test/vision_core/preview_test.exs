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

  # A pair whose depth image is `width` x `height` millimetres from `depth_mm`.
  defp pair(depth_mm \\ nil, {width, height} \\ {4, 4}) do
    frame = %Frame{label: "left", width: width, height: height, capture_ns: 0, jpeg: <<>>}
    depth = depth_mm && for(d <- depth_mm, into: <<>>, do: <<d::little-16>>)

    %Pair{
      left_frame: frame,
      right_frame: %{frame | label: "right"},
      depth: depth,
      geometry: %{width: width, height: height}
    }
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

  @tag :jpeg
  test "a grey frame is previewed as a JPEG" do
    start_supervised!(VisionCore.Jpeg)
    start_supervised!({Preview, config: @config, max_hz: 5})
    :ok = Preview.subscribe(:left)

    frame = %Frame{label: "left", width: 2, height: 2, capture_ns: 1, grey: <<0, 64, 128, 255>>}
    GenServer.cast(Preview, {:camera_frame, frame})

    assert_receive {:vision_preview, :left, <<0xFF, 0xD8, _rest::binary>>}, 1_000
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
    depth_mm = List.duplicate(0, 16)

    GenServer.cast(Preview, {:stereo_pair, pair(depth_mm)})
    refute_receive :depth_encoded, 200

    :ok = Preview.subscribe(:depth)
    GenServer.cast(Preview, {:stereo_pair, pair(depth_mm)})

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

  @tag :jpeg
  test "a depth map that fails to encode is skipped, logged once" do
    start_supervised!(VisionCore.Jpeg)
    preview = start_supervised!({Preview, config: @config, max_hz: 50})
    :ok = Preview.subscribe(:depth)
    # A depth image shorter than its size says.
    truncated = %{pair(List.duplicate(1000, 16)) | geometry: %{width: 8, height: 8}}

    log =
      capture_log(fn ->
        for _ <- 1..3 do
          GenServer.cast(Preview, {:stereo_pair, truncated})
          :sys.get_state(Preview)
          Process.sleep(30)
        end

        refute_receive {:vision_preview, :depth, _jpeg}, 100
      end)

    assert Process.alive?(preview)
    assert length(String.split(log, "depth preview")) == 2

    GenServer.cast(Preview, {:stereo_pair, pair(List.duplicate(1000, 16))})
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

  describe "the depth preview" do
    @describetag :jpeg

    # The decoded preview's mean {blue, green, red} over the columns `columns`.
    defp colour(jpeg, columns) do
      jpeg
      |> Evision.imdecode(Evision.Constant.cv_IMREAD_COLOR())
      |> Evision.Mat.to_nx(Nx.BinaryBackend)
      |> then(& &1[[.., columns, ..]])
      |> Nx.reshape({:auto, 3})
      |> Nx.mean(axes: [0])
      |> Nx.to_list()
    end

    test "is black without depth" do
      start_supervised!(VisionCore.Jpeg)
      jpeg = Preview.encode_depth(pair(List.duplicate(0, 256), {16, 16}), 10.0)

      assert colour(jpeg, 0..15) |> Enum.all?(&(&1 < 4))
    end

    test "is red near the camera over a fixed range" do
      start_supervised!(VisionCore.Jpeg)

      [blue, green, red] =
        colour(Preview.encode_depth(pair(List.duplicate(10, 256), {16, 16}), 10.0), 0..15)

      assert red > 100 and green < 30 and blue < 30
    end

    test "spans the measured depths when the range is automatic" do
      start_supervised!(VisionCore.Jpeg)
      # Left half at 1 m, right half at 3 m.
      depth_mm = for _row <- 1..16, column <- 0..15, do: if(column < 8, do: 1000, else: 3000)
      jpeg = Preview.encode_depth(pair(depth_mm, {16, 16}), 0.0)

      [_blue, _green, near_red] = colour(jpeg, 1..5)
      [far_blue, _green, far_red] = colour(jpeg, 10..14)
      assert near_red > 100
      assert far_blue > far_red
    end
  end

  describe "settings" do
    test "change the rate and the depth range while running" do
      start_supervised!({Preview, config: @config})

      assert %{max_hz: 10, depth_range_m: +0.0} = Preview.options()

      assert {:ok, %{max_hz: 15, depth_range_m: 4.0}} =
               Preview.set_options(max_hz: 15, depth_range_m: 4.0)

      assert :sys.get_state(Preview).interval_ms == div(1_000, 15)
      assert {:error, "max_hz" <> _} = Preview.set_options(max_hz: 0)
    end
  end
end

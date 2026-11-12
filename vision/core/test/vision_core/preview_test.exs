defmodule VisionCore.PreviewTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias VisionCore.Camera.Frame
  alias VisionCore.{Outputs, Preview}
  alias VisionCore.Stereo.Pair

  @config %VisionCore.Config{components: []}

  # Names a stereo unit's cameras, which need not be running.
  defmodule Camera do
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  defp feed_left(sequence) do
    frame = %Frame{label: "left", width: 2, height: 2, capture_ns: sequence, jpeg: "#{sequence}"}
    GenServer.cast(Preview, {:camera_frame, frame})
  end

  # A pair whose depth image is `width` x `height` millimetres from `depth_mm`.
  defp pair(depth_mm \\ nil, {width, height} \\ {4, 4}) do
    frame = %Frame{label: "left", width: width, height: height, capture_ns: 0, jpeg: <<>>}
    depth = depth_mm && for(millimetres <- depth_mm, into: <<>>, do: <<millimetres::little-16>>)

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

  describe "a camera of its own" do
    @camera_config %VisionCore.Config{components: [{:camera, name: :hq, driver: Camera}]}

    defp hq_frame(sequence),
      do: %Frame{label: "hq", width: 2, height: 2, capture_ns: sequence, rgb: <<sequence>>}

    defp publish_hq(frame),
      do: Outputs.publish({:camera_frame, Camera.name_for("hq")}, {:camera_frame, frame})

    test "its frames are previewed as the stream of its name, encoded at the preview's own rate" do
      test_pid = self()

      encode_frame = fn %Frame{rgb: <<sequence>>} ->
        send(test_pid, {:encoded, sequence})
        {:ok, "hq#{sequence}"}
      end

      start_supervised!(
        {Preview, config: @camera_config, max_hz: 50, frame_encoder: encode_frame}
      )

      :ok = Preview.subscribe(:hq)
      refute_receive {:vision_preview, :hq, _}, 50

      publish_hq(hq_frame(1))
      assert_receive {:vision_preview, :hq, "hq1"}, 500

      for sequence <- 2..6, do: publish_hq(hq_frame(sequence))
      :sys.get_state(Preview)
      refute_receive {:vision_preview, :hq, _}, 100

      Preview.ack(:hq)
      assert_receive {:vision_preview, :hq, "hq6"}, 500
      for skipped <- 2..5, do: refute_received({:encoded, ^skipped})
    end

    # Encodes the left frames at once, and each hq frame once the test sends the encode :release.
    defp held_hq_encoder(test_pid) do
      fn
        %Frame{label: "hq", rgb: <<sequence>>} ->
          send(test_pid, {:encoding, self(), sequence})

          receive do
            :release -> {:ok, "hq#{sequence}"}
          end

        %Frame{jpeg: jpeg} ->
          {:ok, jpeg}
      end
    end

    test "a slow stream does not delay another's" do
      start_supervised!(
        {Preview, config: @camera_config, max_hz: 50, frame_encoder: held_hq_encoder(self())}
      )

      :ok = Preview.subscribe(:hq)
      :ok = Preview.subscribe(:left)

      publish_hq(hq_frame(1))
      assert_receive {:encoding, encode, 1}, 500
      feed_left(1)

      assert_receive {:vision_preview, :left, "1"}, 500
      send(encode, :release)
      assert_receive {:vision_preview, :hq, "hq1"}, 500
    end

    test "one frame a stream encodes at a time, the newest waiting, sent though newer came" do
      start_supervised!(
        {Preview, config: @camera_config, max_hz: 50, frame_encoder: held_hq_encoder(self())}
      )

      :ok = Preview.subscribe(:hq)
      publish_hq(hq_frame(1))
      assert_receive {:encoding, encode, 1}, 500

      for sequence <- 2..4, do: publish_hq(hq_frame(sequence))
      :sys.get_state(Preview)
      refute_receive {:encoding, _encode, _sequence}, 100

      send(encode, :release)
      assert_receive {:vision_preview, :hq, "hq1"}, 500
      Preview.ack(:hq)

      assert_receive {:encoding, encode, 4}, 500
      send(encode, :release)
      assert_receive {:vision_preview, :hq, "hq4"}, 500
      refute_received {:encoding, _encode, _skipped}
    end

    test "a stream's frames reach only its subscribers" do
      start_supervised!({Preview, config: @camera_config, max_hz: 50})
      :ok = Preview.subscribe(:left)

      publish_hq(%{hq_frame(1) | jpeg: "hq"})
      :sys.get_state(Preview)

      refute_receive {:vision_preview, _stream, _jpeg}, 100
    end

    test "its stream shows its default output, or the one :outputs names" do
      camera = [
        name: :hq,
        driver: VisionCore.Camera.V4L2Single,
        outputs: [
          view: [resolution: {2028, 1520}, processor: :cpu],
          inference: [resolution: {1014, 760}, from: :view]
        ]
      ]

      config = %VisionCore.Config{components: [{:camera, camera}]}
      server = VisionCore.Camera.V4L2Single.name_for("hq")
      encode_frame = fn %Frame{output: output} -> {:ok, "#{output}"} end

      preview =
        start_supervised!({Preview, config: config, max_hz: 50, frame_encoder: encode_frame})

      assert preview in Outputs.subscribers({:camera_frame, server, :view})
      refute preview in Outputs.subscribers({:camera_frame, server, :inference})
      stop_supervised!(Preview)

      preview =
        start_supervised!(
          {Preview,
           config: config, max_hz: 50, frame_encoder: encode_frame, outputs: [hq: :inference]}
        )

      refute preview in Outputs.subscribers({:camera_frame, server, :view})
      :ok = Preview.subscribe(:hq)

      Outputs.publish(
        {:camera_frame, server, :inference},
        {:camera_frame, %{hq_frame(1) | output: :inference}}
      )

      assert_receive {:vision_preview, :hq, "inference"}, 500
    end

    test "its stream shows its camera's first sent output, not one it does not send" do
      camera = [
        name: :hq,
        driver: VisionCore.Camera.V4L2Single,
        outputs: [
          view: [resolution: {2028, 1520}, processor: :cpu, send: false],
          view_jpeg: [from: :view, format: :jpeg],
          inference: [resolution: {1014, 760}, from: :view]
        ]
      ]

      config = %VisionCore.Config{components: [{:camera, camera}]}
      server = VisionCore.Camera.V4L2Single.name_for("hq")

      preview = start_supervised!({Preview, config: config, max_hz: 50})
      assert preview in Outputs.subscribers({:camera_frame, server, :view_jpeg})
      stop_supervised!(Preview)

      log =
        capture_log(fn ->
          preview = start_supervised!({Preview, config: config, max_hz: 50, outputs: [hq: :view]})
          assert preview in Outputs.subscribers({:camera_frame, server, :view_jpeg})
          refute preview in Outputs.subscribers({:camera_frame, server, :view})
        end)

      assert log =~
               "camera hq does not send its output :view (send: false); " <>
                 "its stream shows its default output"
    end

    test "a camera's JPEG output is previewed as the camera sent it, without an encode" do
      camera = [
        name: :hq,
        driver: VisionCore.Camera.V4L2Single,
        outputs: [
          view: [resolution: {2028, 1520}, processor: :cpu],
          view_jpeg: [from: :view, format: :jpeg]
        ]
      ]

      config = %VisionCore.Config{components: [{:camera, camera}]}
      server = VisionCore.Camera.V4L2Single.name_for("hq")
      no_codec = Module.concat(__MODULE__, NoCodec)

      start_supervised!(
        {Preview, config: config, max_hz: 50, outputs: [hq: :view_jpeg], jpeg_codec: no_codec}
      )

      :ok = Preview.subscribe(:hq)
      jpeg = <<0xFF, 0xD8, 9, 8, 7, 0xFF, 0xD9>>

      frame = %Frame{
        label: "hq",
        output: :view_jpeg,
        width: 2028,
        height: 1520,
        capture_ns: 1,
        jpeg: jpeg
      }

      Outputs.publish({:camera_frame, server, :view_jpeg}, {:camera_frame, frame})
      assert_receive {:vision_preview, :hq, ^jpeg}, 500
    end

    test "a camera whose outputs cannot be made has nothing to show, and the rest previews on" do
      camera = [
        name: :hq,
        driver: VisionCore.Camera.V4L2Single,
        outputs: [view: [resolution: {640, 480}, processor: :cpu]]
      ]

      config = %VisionCore.Config{components: [{:camera, camera}]}
      preview = start_supervised!({Preview, config: config, max_hz: 50})

      refute preview in Outputs.subscribers(nil)
      assert Preview.subscribe(:hq) == :ok
    end

    test "a stream the configuration has no camera for cannot be subscribed to" do
      start_supervised!({Preview, config: @camera_config, max_hz: 50})

      assert Preview.subscribe(:other) == {:error, :unknown_stream}
      assert Preview.subscribe(:hq) == :ok
    end
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

  @tag :jpeg
  test "encodes on the JPEG codec its :jpeg_codec option names" do
    start_supervised!({VisionCore.Jpeg, name: :preview_test_codec})
    start_supervised!({Preview, config: @config, max_hz: 50, jpeg_codec: :preview_test_codec})
    :ok = Preview.subscribe(:left)
    :ok = Preview.subscribe(:depth)
    frame = %Frame{label: "left", width: 2, height: 2, capture_ns: 1, grey: <<0, 64, 128, 255>>}

    GenServer.cast(Preview, {:camera_frame, frame})
    GenServer.cast(Preview, {:stereo_pair, pair(List.duplicate(1000, 16))})

    assert_receive {:vision_preview, :left, <<0xFF, 0xD8, _rest::binary>>}, 1_000
    assert_receive {:vision_preview, :depth, <<0xFF, 0xD8, _rest::binary>>}, 1_000
    assert Process.whereis(VisionCore.Jpeg) == nil
  end

  test "the previews and an exporter encoding back to back share one Port, neither starving" do
    path = Application.get_env(:vision_core, :jpeg_codec_path)
    on_exit(fn -> Application.put_env(:vision_core, :jpeg_codec_path, path) end)
    fake_codec = Path.expand("../support/slow_jpeg_codec.py", __DIR__)
    Application.put_env(:vision_core, :jpeg_codec_path, fake_codec)
    start_supervised!({VisionCore.Jpeg, name: :shared_codec, ports: 1})
    test_pid = self()

    # Each of its encodes is a slow one on the fake codec, answered "slow".
    export = fn ->
      reply = VisionCore.Jpeg.encode(<<1>>, 1, 1, 1, codec: :shared_codec)
      send(test_pid, {:exported, reply})
    end

    start_supervised!({Task, fn -> Stream.repeatedly(export) |> Stream.run() end})
    start_supervised!({Preview, config: @config, max_hz: 50, jpeg_codec: :shared_codec})
    :ok = Preview.subscribe(:left)

    for sequence <- 1..2 do
      frame = %Frame{label: "left", width: 1, height: 1, capture_ns: sequence, grey: <<0>>}
      GenServer.cast(Preview, {:camera_frame, frame})
      assert_receive {:vision_preview, :left, "fast"}, 1_500
      Preview.ack(:left)
    end

    assert_receive {:exported, {:ok, "slow"}}, 1_500
    assert_receive {:exported, {:ok, "slow"}}, 1_500
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

  test "a camera frame is encoded once, however many subscribers receive it" do
    test_pid = self()

    encode_frame = fn frame ->
      send(test_pid, :frame_encoded)
      {:ok, frame.jpeg}
    end

    start_supervised!({Preview, config: @config, max_hz: 50, frame_encoder: encode_frame})
    subscribers = for _ <- 1..3, do: spawn_subscriber(test_pid)
    for pid <- subscribers, do: assert_receive({:subscribed, ^pid}, 500)

    feed_left(1)

    for _ <- subscribers, do: assert_receive({:previewed, "1"}, 500)
    assert_received :frame_encoded
    refute_received :frame_encoded
  end

  defp spawn_subscriber(test_pid) do
    spawn_link(fn ->
      :ok = Preview.subscribe(:left)
      send(test_pid, {:subscribed, self()})

      receive do
        {:vision_preview, :left, jpeg} -> send(test_pid, {:previewed, jpeg})
      end

      Process.sleep(:infinity)
    end)
  end

  test "a new depth range is told to every depth subscriber, whoever set it" do
    start_supervised!({Preview, config: @config})
    :ok = Preview.subscribe(:depth)
    left_only = spawn_subscriber(self())
    assert_receive {:subscribed, ^left_only}, 500

    assert {:ok, _options} = Preview.set_options(depth_range_m: 8.5)

    assert_receive {:vision_preview_options, %{depth_range_m: 8.5}}, 500
    refute_receive {:previewed, _jpeg}, 100
  end

  test "previews what the stereo unit of its config publishes" do
    stereo = {:stereo, driver: Camera, left: [], right: []}
    depth_encoder = fn _pair -> "depth jpeg" end
    config = %{@config | components: [stereo]}
    start_supervised!({Preview, config: config, depth_encoder: depth_encoder})
    :ok = Preview.subscribe(:left)
    :ok = Preview.subscribe(:depth)
    frame = %Frame{label: "left", width: 2, height: 2, capture_ns: 1, jpeg: "left jpeg"}

    Outputs.publish({:camera_frame, Camera.name_for("left")}, {:camera_frame, frame})

    Outputs.publish(
      {:stereo_pair, VisionCore.Stereo.Pipeline},
      {:stereo_pair, pair(List.duplicate(0, 16))}
    )

    assert_receive {:vision_preview, :left, "left jpeg"}, 1_000
    assert_receive {:vision_preview, :depth, "depth jpeg"}, 1_000
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

  test "the latest depth map is coloured again over a new depth range" do
    test_pid = self()

    encode_depth = fn _pair ->
      send(test_pid, :depth_encoded)
      "depth jpeg"
    end

    start_supervised!({Preview, config: @config, depth_encoder: encode_depth})
    :ok = Preview.subscribe(:depth)
    GenServer.cast(Preview, {:stereo_pair, pair(List.duplicate(0, 16))})
    assert_receive {:vision_preview, :depth, "depth jpeg"}, 500
    assert_received :depth_encoded

    assert {:ok, _options} = Preview.set_options(depth_range_m: 8.5)
    Preview.ack(:depth)

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

  describe "composer options" do
    test "the preview's settings come from the composer's preview options" do
      start_supervised!({Preview, config: @config, max_hz: 15})

      assert %{max_hz: 15} = Preview.options()
    end
  end
end

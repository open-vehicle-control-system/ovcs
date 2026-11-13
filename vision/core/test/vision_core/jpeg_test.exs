defmodule VisionCore.JpegTest do
  use ExUnit.Case, async: false

  alias VisionCore.Camera.Frame
  alias VisionCore.Jpeg

  @moduletag :jpeg

  setup do
    start_supervised!(Jpeg)
    :ok
  end

  test "a grey image survives the round trip" do
    gradient = Nx.iota({48, 64}, axis: 1, type: :u8) |> Nx.multiply(4)

    {:ok, jpeg} = Jpeg.encode_tensor(gradient)

    decoded =
      jpeg
      |> Evision.imdecode(Evision.Constant.cv_IMREAD_GRAYSCALE())
      |> Evision.Mat.to_nx(Nx.BinaryBackend)

    difference = Nx.subtract(Nx.as_type(decoded, :s16), Nx.as_type(gradient, :s16))
    assert difference |> Nx.abs() |> Nx.reduce_max() |> Nx.to_number() <= 8
  end

  test "a JPEG decodes to its grey pixels" do
    gradient = Nx.iota({48, 64}, axis: 1, type: :u8) |> Nx.multiply(4)
    {:ok, jpeg} = Jpeg.encode_tensor(gradient)

    assert {:ok, {64, 48, pixels}} = Jpeg.decode_grey(jpeg)
    decoded = Nx.from_binary(pixels, :u8) |> Nx.reshape({48, 64})
    difference = Nx.subtract(Nx.as_type(decoded, :s16), Nx.as_type(gradient, :s16))
    assert difference |> Nx.abs() |> Nx.reduce_max() |> Nx.to_number() <= 8
  end

  test "data that is not a JPEG does not decode" do
    assert {:error, :bad_request} = Jpeg.decode_grey("not a jpeg")
  end

  test "an RGB image is encoded" do
    image = Nx.broadcast(Nx.tensor([200, 30, 30], type: :u8), {8, 8, 3})
    assert {:ok, <<0xFF, 0xD8, _rest::binary>>} = Jpeg.encode_tensor(image)
  end

  test "a second instance runs under its own name, on a Port of its own" do
    start_supervised!({Jpeg, name: :second_codec})
    image = Nx.broadcast(Nx.tensor(128, type: :u8), {8, 8})

    assert {:ok, jpeg} = Jpeg.encode_tensor(image, codec: :second_codec)
    assert {:ok, {8, 8, _pixels}} = Jpeg.decode_grey(jpeg, codec: :second_codec)
    assert :sys.get_state(Jpeg).ports == %{}
  end

  test "encodes at the quality asked for" do
    image = Nx.iota({32, 32}, type: :u8)

    {:ok, low} = Jpeg.encode_tensor(image, quality: 10)
    {:ok, high} = Jpeg.encode_tensor(image, quality: 95)

    assert byte_size(low) < byte_size(high)
  end

  test "a missing encoder is an error, not a crash" do
    path = Application.get_env(:vision_core, :jpeg_codec_path)
    on_exit(fn -> Application.put_env(:vision_core, :jpeg_codec_path, path) end)
    Application.put_env(:vision_core, :jpeg_codec_path, "/nonexistent/jpeg_codec")
    stop_supervised!(Jpeg)
    start_supervised!(Jpeg)

    assert {:error, {:no_encoder, "/nonexistent/jpeg_codec"}} = Jpeg.encode(<<0>>, 1, 1, 1)
  end

  describe "a pool of Ports" do
    setup do
      path = Application.get_env(:vision_core, :jpeg_codec_path)
      on_exit(fn -> Application.put_env(:vision_core, :jpeg_codec_path, path) end)

      Application.put_env(
        :vision_core,
        :jpeg_codec_path,
        Path.expand("../support/slow_jpeg_codec.py", __DIR__)
      )

      stop_supervised!(Jpeg)
      :ok
    end

    # The fake jpeg_codec answers by a request's last byte; see slow_jpeg_codec.py.
    defp fake(byte), do: Jpeg.encode(<<byte>>, 1, 1, 1)
    defp slow, do: Task.async(fn -> fake(1) end)

    # Waits until a request is on a Port, so the next one cannot overtake it.
    defp await_busy_port(deadline_ms \\ System.monotonic_time(:millisecond) + 1_000) do
      cond do
        Enum.any?(Map.values(:sys.get_state(Jpeg).ports)) -> :ok
        System.monotonic_time(:millisecond) > deadline_ms -> flunk("no request reached a Port")
        true -> await_busy_port(deadline_ms)
      end
    end

    test "a late reply does not reach the next caller" do
      start_supervised!({Jpeg, ports: 1, timeout_ms: 100})

      assert {:error, :timeout} = fake(1)
      assert {:ok, "fast"} = fake(0)
    end

    test "a request runs on a free Port while another Port encodes" do
      start_supervised!({Jpeg, ports: 2})
      slow = slow()
      await_busy_port()

      assert {:ok, "fast"} = fake(0)
      assert Task.yield(slow, 0) == nil
      assert {:ok, "slow"} = Task.await(slow)
    end

    test "requests wait for a Port once every Port is busy, served in arrival order" do
      start_supervised!({Jpeg, ports: 1})
      test_pid = self()

      Task.start_link(fn ->
        for round <- 1..3, do: send(test_pid, {:steady, round, fake(1)})
      end)

      await_busy_port()
      assert {:ok, "fast"} = fake(0)

      assert_receive {:steady, 1, {:ok, "slow"}}
      refute_received {:steady, 2, _reply}
      assert_receive {:steady, 3, {:ok, "slow"}}, 2_000
    end

    test "a free Port takes the next request rather than a new Port" do
      start_supervised!({Jpeg, ports: 3})

      assert {:ok, codec_pid} = fake(3)
      assert {:ok, ^codec_pid} = fake(3)
    end

    @tag :capture_log
    test "a Port that exits fails its own request only, and reopens on the next" do
      start_supervised!({Jpeg, ports: 2})
      slow = slow()
      await_busy_port()

      assert {:error, {:exited, 3}} = fake(2)
      assert {:ok, "slow"} = Task.await(slow)
      assert {:ok, "fast"} = fake(0)
    end

    # A request for the frame captured at `capture_ns` of the left camera's stream.
    defp frame_request(byte, capture_ns, options \\ []),
      do: Jpeg.encode(<<byte>>, 1, 1, 1, [frame: {{"left", nil}, capture_ns}] ++ options)

    test "requests for one frame at one quality share one encode while it runs" do
      start_supervised!({Jpeg, ports: 2})
      first = Task.async(fn -> frame_request(1, 7) end)
      await_busy_port()
      second = Task.async(fn -> frame_request(1, 7) end)

      assert {:ok, "slow"} = Task.await(first)
      assert {:ok, "slow"} = Task.await(second)
      assert map_size(:sys.get_state(Jpeg).ports) == 1
    end

    test "two consumers encoding one camera frame share its encode" do
      start_supervised!({Jpeg, ports: 2})
      frame = %Frame{label: "left", width: 1, height: 1, capture_ns: 7, grey: <<1>>}
      first = Task.async(fn -> Frame.to_jpeg(frame, Jpeg) end)
      await_busy_port()
      second = Task.async(fn -> Frame.to_jpeg(frame, Jpeg) end)

      assert {:ok, "slow"} = Task.await(first)
      assert {:ok, "slow"} = Task.await(second)
      assert map_size(:sys.get_state(Jpeg).ports) == 1
    end

    test "a request for the frame a stream encoded last takes its JPEG without an encode" do
      start_supervised!({Jpeg, ports: 1})

      assert {:ok, codec_pid} = frame_request(3, 7)
      assert {:ok, ^codec_pid} = frame_request(0, 7)
    end

    test "another quality, another frame, another stream or no frame is encoded" do
      start_supervised!({Jpeg, ports: 1})
      {:ok, _codec_pid} = frame_request(3, 7)

      assert {:ok, "fast"} = frame_request(0, 7, quality: 90)
      assert {:ok, "fast"} = frame_request(0, 8)
      assert {:ok, "fast"} = Jpeg.encode(<<0>>, 1, 1, 1, frame: {{"right", nil}, 8})
      assert {:ok, "fast"} = Jpeg.encode(<<0>>, 1, 1, 1)
    end

    test "each stream keeps only the JPEG of its latest frame" do
      start_supervised!({Jpeg, ports: 1})
      {:ok, _codec_pid} = frame_request(3, 7)
      {:ok, "fast"} = frame_request(0, 8)

      assert {:ok, "fast"} = frame_request(0, 7)
      assert {:ok, "fast"} = frame_request(3, 8)
      assert map_size(:sys.get_state(Jpeg).finished) == 1
    end

    test "a shared encode that fails answers each request with its error and is not kept" do
      start_supervised!({Jpeg, ports: 1, timeout_ms: 100})
      first = Task.async(fn -> frame_request(1, 7) end)
      await_busy_port()
      second = Task.async(fn -> frame_request(1, 7) end)

      assert {:error, :timeout} = Task.await(first)
      assert {:error, :timeout} = Task.await(second)
      assert {:ok, "fast"} = frame_request(0, 7)
    end

    test "its size is a positive integer" do
      for ports <- [0, -1, 1.5, :three] do
        assert_raise ArgumentError, ~r/:ports/, fn -> Jpeg.start_link(ports: ports) end
      end
    end
  end
end

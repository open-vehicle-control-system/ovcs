defmodule VisionCore.JpegTest do
  use ExUnit.Case, async: false

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
    assert :sys.get_state(Jpeg).port == nil
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

  test "a late reply does not reach the next caller" do
    path = Application.get_env(:vision_core, :jpeg_codec_path)
    on_exit(fn -> Application.put_env(:vision_core, :jpeg_codec_path, path) end)

    Application.put_env(
      :vision_core,
      :jpeg_codec_path,
      Path.expand("../support/slow_jpeg_codec.py", __DIR__)
    )

    stop_supervised!(Jpeg)
    start_supervised!({Jpeg, timeout_ms: 100})

    assert {:error, :timeout} = Jpeg.encode(<<1>>, 1, 1, 1)
    assert {:ok, "fast"} = Jpeg.encode(<<0>>, 1, 1, 1)
  end
end

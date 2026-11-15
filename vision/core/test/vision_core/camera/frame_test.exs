defmodule VisionCore.Camera.FrameTest do
  use ExUnit.Case, async: false

  alias VisionCore.Camera.Frame

  @grey %Frame{
    label: "left",
    width: 4,
    height: 2,
    capture_ns: 0,
    grey: <<1, 2, 3, 4, 5, 6, 7, 8>>
  }

  test "a grey frame becomes a u8 tensor with its bytes" do
    {:ok, image} = Frame.to_tensor(@grey)

    assert Nx.shape(image) == {2, 4}
    assert Nx.to_binary(image) == <<1, 2, 3, 4, 5, 6, 7, 8>>
  end

  @rgb %Frame{
    label: "hq",
    width: 2,
    height: 2,
    capture_ns: 0,
    rgb: <<255, 0, 0, 0, 255, 0, 0, 0, 255, 10, 20, 30>>
  }

  test "an RGB frame becomes a u8 height x width x 3 tensor with its bytes" do
    {:ok, image} = Frame.to_tensor(@rgb)

    assert Nx.shape(image) == {2, 2, 3}
    assert Nx.type(image) == {:u, 8}
    assert Nx.to_binary(image) == @rgb.rgb
    assert Nx.to_flat_list(image[0][1]) == [0, 255, 0]
  end

  @tag :jpeg
  test "an RGB frame is encoded to a colour JPEG" do
    start_supervised!(VisionCore.Jpeg)
    assert {:ok, <<0xFF, 0xD8, _rest::binary>> = jpeg} = Frame.to_jpeg(@rgb)

    assert %Evision.Mat{shape: {2, 2, 3}} =
             Evision.imdecode(jpeg, Evision.Constant.cv_IMREAD_UNCHANGED())
  end

  @tag :jpeg
  test "a grey frame is encoded to JPEG" do
    start_supervised!(VisionCore.Jpeg)
    assert {:ok, <<0xFF, 0xD8, _rest::binary>>} = Frame.to_jpeg(@grey)
  end

  @tag :jpeg
  test "a grey frame is encoded on the codec instance given" do
    start_supervised!({VisionCore.Jpeg, name: :frame_test_codec})
    assert {:ok, <<0xFF, 0xD8, _rest::binary>>} = Frame.to_jpeg(@grey, :frame_test_codec)
  end

  @tag :jpeg
  test "a JPEG frame keeps its bytes and decodes to grey" do
    start_supervised!(VisionCore.Jpeg)
    {:ok, jpeg} = Frame.to_jpeg(@grey)
    frame = %Frame{label: "left", width: 4, height: 2, capture_ns: 0, jpeg: jpeg}

    assert Frame.to_jpeg(frame) == {:ok, jpeg}
    assert {:ok, image} = Frame.to_tensor(frame)
    assert Nx.shape(image) == {2, 4}
  end

  @tag :jpeg
  test "a JPEG that does not decode is an error" do
    start_supervised!(VisionCore.Jpeg)
    frame = %Frame{label: "left", width: 4, height: 2, capture_ns: 0, jpeg: "not a jpeg"}
    assert {:error, {:jpeg, _reason}} = Frame.to_tensor(frame)
    assert {:error, {:jpeg, _reason}} = Frame.to_tensor(frame, colour: true)
  end

  @tag :jpeg
  test "in colour, a JPEG frame decodes to RGB, and a grey or RGB frame stays as it is" do
    start_supervised!(VisionCore.Jpeg)
    {:ok, jpeg} = Frame.to_jpeg(@rgb)
    frame = %Frame{label: "hq", width: 2, height: 2, capture_ns: 0, jpeg: jpeg}

    assert {:ok, image} = Frame.to_tensor(frame, colour: true)
    assert Nx.shape(image) == {2, 2, 3}
    assert Frame.to_tensor(@rgb, colour: true) == Frame.to_tensor(@rgb)
    assert Frame.to_tensor(@grey, colour: true) == Frame.to_tensor(@grey)
  end

  @tag :jpeg
  test "in colour, a frame's RGB pixels: a JPEG's decoded, none for a grey frame" do
    start_supervised!(VisionCore.Jpeg)
    {:ok, jpeg} = Frame.to_jpeg(@rgb)
    frame = %Frame{label: "hq", width: 2, height: 2, capture_ns: 0, jpeg: jpeg}

    assert {:ok, %Frame{rgb: rgb, jpeg: ^jpeg}} = Frame.with_rgb(frame)
    assert byte_size(rgb) == 2 * 2 * 3
    assert Frame.with_rgb(@rgb) == {:ok, @rgb}
    assert Frame.with_rgb(@grey) == {:error, :colourless}
  end
end

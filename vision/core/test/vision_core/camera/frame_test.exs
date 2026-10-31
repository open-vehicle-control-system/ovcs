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

  @tag :jpeg
  test "a grey frame is encoded to JPEG" do
    start_supervised!(VisionCore.Jpeg)
    assert {:ok, <<0xFF, 0xD8, _rest::binary>>} = Frame.to_jpeg(@grey)
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
  end
end

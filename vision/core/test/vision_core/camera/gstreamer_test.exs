defmodule VisionCore.Camera.GStreamerTest do
  use ExUnit.Case, async: true

  alias VisionCore.Camera.{Frame, GStreamer}
  alias VisionCore.Outputs

  test "publishes each JPEG of the stream as a frame under its label" do
    output = {:camera_frame, GStreamer.name_for("left")}
    :ok = Outputs.subscribe(output)
    state = %{label: "left", width: 2, height: 2, port: :port, buffer: <<>>, output: output}
    jpeg = <<0xFF, 0xD8, 1, 2, 0xFF, 0xD9>>

    assert {:noreply, %{buffer: <<0xFF, 0xD8>>}} =
             GStreamer.handle_info({:port, {:data, jpeg <> <<0xFF, 0xD8>>}}, state)

    assert_receive {:"$gen_cast", {:camera_frame, %Frame{label: "left", jpeg: ^jpeg}}}
  end
end

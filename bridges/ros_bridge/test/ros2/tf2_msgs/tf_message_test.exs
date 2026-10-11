defmodule Ros2.Tf2Msgs.Msg.TFMessageTest do
  @moduledoc """
  Byte layout of the single-transform message built by `message/0`:

  ```text
   0  sequence count             u32         ->  4
   4  Time sec + nanosec         2 x 4       -> 12
  12  "base_link"   4 + 10 + 2 pad           -> 28
  28  "stereo_left" 4 + 12 + 0 pad           -> 44
  44  padding to the next 8-boundary         -> 48
  48  Transform: 7 x float64                 -> 104
  ```
  """
  use ExUnit.Case, async: true

  alias Ros2.BuiltinInterfaces.Msg.Time
  alias Ros2.GeometryMsgs.Msg.{Quaternion, Transform, TransformStamped, Vector3}
  alias Ros2.StdMsgs.Msg.Header
  alias Ros2.Tf2Msgs.Msg.TFMessage

  defp message do
    %TFMessage{
      transforms: [
        %TransformStamped{
          header: %Header{stamp: %Time{sec: 7, nanosec: 8}, frame_id: "base_link"},
          child_frame_id: "stereo_left",
          transform: %Transform{
            translation: %Vector3{x: 0.10, y: 0.0, z: 0.12},
            rotation: %Quaternion{x: -0.5, y: 0.5, z: -0.5, w: 0.5}
          }
        }
      ]
    }
  end

  test "places the Transform on an 8-byte boundary from the body origin" do
    body = TFMessage.encode(message())

    assert byte_size(body) == 104

    # Aligning inside TransformStamped, from a buffer starting at 0,
    # finds offset 40 already aligned and encodes 4 bytes short; Fast CDR
    # then fails with "Not enough memory in the buffer stream".
    <<_::binary-size(48), tx::little-float-64, ty::little-float-64, tz::little-float-64,
      rx::little-float-64, ry::little-float-64, rz::little-float-64, rw::little-float-64>> = body

    assert tx == 0.10
    assert ty == 0.0
    assert tz == 0.12
    assert {rx, ry, rz, rw} == {-0.5, 0.5, -0.5, 0.5}
  end

  test "an empty transform list encodes as a bare zero count" do
    assert TFMessage.encode(%TFMessage{transforms: []}) == <<0, 0, 0, 0>>
  end

  test "consecutive transforms stay aligned" do
    two_transforms = %TFMessage{transforms: message().transforms ++ message().transforms}
    body = TFMessage.encode(two_transforms)

    # The second element starts at 104 and reaches its Transform at 144,
    # already 8-aligned, so it takes 96 bytes to the first's 100: padding
    # depends on position in the message, not on the struct.
    assert byte_size(body) == 200
    assert rem(byte_size(body), 8) == 0
  end
end

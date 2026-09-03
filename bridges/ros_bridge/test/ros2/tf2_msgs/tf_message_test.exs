defmodule Ros2.Tf2Msgs.Msg.TFMessageTest do
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

    #  0  sequence count             u32         ->  4
    #  4  Time sec + nanosec         2 x 4       -> 12
    # 12  "base_link"   4 + 10 + 2 pad           -> 28
    # 28  "stereo_left" 4 + 12 + 0 pad           -> 44
    # 44  padding to the next 8-boundary         -> 48
    # 48  Transform: 7 x float64                 -> 104
    assert byte_size(body) == 104

    # The bug this guards: aligning inside TransformStamped, where the
    # buffer starts at 0, finds offset 40 already aligned and adds no
    # padding — the message encodes 4 bytes short and Fast CDR fails
    # with "Not enough memory in the buffer stream".
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
    two = %TFMessage{transforms: message().transforms ++ message().transforms}
    body = TFMessage.encode(two)

    # The second element costs 96 bytes, not the first one's 100: it
    # starts at 104 and reaches its Transform at 144, which is already
    # 8-aligned, so it needs no padding where the first needed 4.
    # Padding is a function of position in the message, which is the
    # whole reason alignment cannot be computed struct-locally.
    assert byte_size(body) == 200
    assert rem(byte_size(body), 8) == 0
  end
end

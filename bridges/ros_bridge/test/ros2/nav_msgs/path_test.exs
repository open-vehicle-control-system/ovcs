defmodule Ros2.NavMsgs.Msg.PathTest do
  @moduledoc """
  The wire layout: each pose's header and pose are aligned against the
  body origin, wherever the previous pose ended.
  """
  use ExUnit.Case, async: true

  alias Ros2.BuiltinInterfaces.Msg.Time
  alias Ros2.GeometryMsgs.Msg.{Point, Pose, PoseStamped}
  alias Ros2.NavMsgs.Msg.Path
  alias Ros2.StdMsgs.Msg.Header

  defp header, do: %Header{stamp: %Time{sec: 1, nanosec: 2}, frame_id: "base_link"}

  defp pose(x), do: %PoseStamped{header: header(), pose: %Pose{position: %Point{x: x}}}

  test "poses land 8-aligned after their headers" do
    body = Path.encode(%Path{header: header(), poses: [pose(1.5), pose(-2.0)]})
    # Header 8 + 14 ("base_link" with its NUL) = 22, padded to 24, count to 28.
    # Each pose: header 22 from 28 to 50, padded to 56, pose 56 bytes to 112.
    <<_::binary-size(24), count::little-32, _::binary-size(28), x1::little-float-64, _::binary>> =
      body

    assert count == 2
    assert x1 == 1.5
    <<_::binary-size(112), _::binary-size(24), x2::little-float-64, _::binary>> = body
    assert x2 == -2.0
    assert byte_size(body) == 112 + 24 + 56
  end
end

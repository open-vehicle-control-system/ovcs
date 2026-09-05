defmodule Ros2.GeometryMsgs.Msg.TwistTest do
  @moduledoc """
  Parses real `geometry_msgs/Twist` and `TwistStamped` bytes,
  serialised by `rclpy` on a Lyrical runtime rather than assembled by
  hand.

  Hand-built fixtures are the wrong tool for the thing that actually
  breaks here. `Twist` opens with a `float64`, so it must start
  8-aligned; nested after a `Header` — whose trailing `frame_id`
  string pads only to 4 — that is not automatic, and how much padding
  sits between them depends on the *length of the frame id*. A
  hand-built fixture encodes an assumption about that; a capture
  encodes the fact.

  The captures below make one more thing explicit that no
  hand-assembled fixture would: **CDR padding is not zeroed.** In the
  `odom` capture the seven padding bytes read `6c 69 6e 6b 00 00 00` —
  "link", left over from a previous message in Fast-CDR's reused
  buffer. A parser that skipped padding by scanning for zeros would
  walk straight into the float. Padding has to be skipped by computed
  offset, which is what these tests pin.
  """
  use ExUnit.Case, async: true

  alias Ros2.GeometryMsgs.Msg.{Twist, TwistStamped}

  # Verbatim from `rclpy.serialization.serialize_message`, including
  # the 4-byte CDR encapsulation header. `parse/1` takes the body,
  # so the helper strips it — the same thing `Ros2.RmwZenoh` does.
  @twist "00010000000000000000f83f000000000000d0bf000000000000000000000000000000000000000000000000000000000000e83f"

  @twist_stamped "000100008085746715cd5b070a000000626173655f6c696e6b000c08000000000000f83f000000000000d0bf000000000000000000000000000000000000000000000000000000000000e83f"

  # frame_id "odom" — 5 bytes with the NUL, so 7 bytes of padding
  # before the Twist, and those bytes carry junk.
  @twist_stamped_short "000100000700000008000000050000006f646f6d006c696e6b000c0800000000000000400000000000000000000000000000000000000000000000000000000000000000000000000000f4bf"

  defp body(hex) do
    <<_encapsulation::binary-size(4), body::binary>> = Base.decode16!(hex, case: :lower)
    body
  end

  describe "Twist" do
    test "parses the six float64s in REP-103 order" do
      assert {:ok, twist, <<>>} = Twist.parse(body(@twist))

      assert twist.linear.x == 1.5
      assert twist.linear.y == -0.25
      assert twist.linear.z == 0.0
      assert twist.angular.x == 0.0
      assert twist.angular.y == 0.0
      assert twist.angular.z == 0.75
    end

    test "a truncated body is an error, not a partial struct" do
      <<short::binary-size(24), _::binary>> = body(@twist)
      assert {:error, :malformed, _} = Twist.parse(short)
    end
  end

  describe "TwistStamped" do
    test "parses the header and the twist behind it" do
      assert {:ok, stamped, <<>>} = TwistStamped.parse(body(@twist_stamped))

      assert stamped.header.stamp.sec == 1_735_689_600
      assert stamped.header.stamp.nanosec == 123_456_789
      assert stamped.header.frame_id == "base_link"
      assert stamped.twist.linear.x == 1.5
      assert stamped.twist.angular.z == 0.75
    end

    test "a shorter frame id shifts the padding, and the twist still lands" do
      # "odom" against "base_link": 2 bytes of padding become 7. If the
      # alignment were computed from the start of the Twist rather than
      # from the body origin, this is the case that would decode to
      # nonsense while the other one passed.
      assert {:ok, stamped, <<>>} = TwistStamped.parse(body(@twist_stamped_short))

      assert stamped.header.frame_id == "odom"
      assert stamped.header.stamp.sec == 7
      assert stamped.header.stamp.nanosec == 8
      assert stamped.twist.linear.x == 2.0
      assert stamped.twist.angular.z == -1.25
    end

    test "the padding really does contain junk" do
      # Guards the claim in the moduledoc: if a future capture happened
      # to zero-fill, a parser bug that scanned for zeros would start
      # passing and this test would stop justifying itself.
      raw = body(@twist_stamped_short)
      # sec + nanosec + length + "odom\0" = 17 bytes consumed, then 7
      # of padding before the 8-aligned Twist. Captured as
      # "link" <> <<0, 0x0c, 0x08>>.
      <<_consumed::binary-size(17), padding::binary-size(7), _twist::binary>> = raw
      refute padding == <<0, 0, 0, 0, 0, 0, 0>>
      assert binary_part(padding, 0, 4) == "link"
    end
  end
end

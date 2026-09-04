defmodule RosBridge.ZenohClientSampleTest do
  @moduledoc """
  A malformed sample must not kill the client.

  This is the blast radius rather than the bug: consumers call
  `ZenohClient.subscribe/2` from `init/1` only, and every supervisor in
  the bridge is `:one_for_one`, so if the client dies it restarts with
  an empty subscription map while the surviving consumers are never
  re-subscribed. One short frame on one topic and the whole bridge goes
  permanently deaf -- no joystick, no IMU, no heartbeat, no cameras --
  until the BEAM restarts. The watchdogs then zero the throttle, with
  nothing in the log naming the cause.

  The parsers are built from binary pattern matches, so a truncated
  body raises (`FunctionClauseError` from a `parse_string/1` clause,
  `MatchError` from an alignment helper, `ArgumentError` from
  `binary_part/3` with a negative length) instead of returning a tagged
  error. `deliver_sample/3`'s `with/else` only ever caught the tagged
  kind.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias RosBridge.ZenohClient
  alias RosBridge.ZenohClient.State
  alias Ros2.GeometryMsgs.Msg.{Twist, TwistStamped}

  @key "0/cmd_vel_nav/**"
  # rmw_zenoh's CDR header: little-endian, no options.
  @cdr_header <<0x00, 0x01, 0x00, 0x00>>

  defp state(message_module) do
    %State{
      subscriptions: %{
        @key => %{
          topic: "cmd_vel_nav",
          message_module: message_module,
          subscribers: %{self() => make_ref()},
          subscriber_id: 1
        }
      }
    }
  end

  defp sample(state, body) do
    ZenohClient.handle_info(
      %Zenohex.Sample{key_expr: "0/cmd_vel_nav/msg", payload: @cdr_header <> body},
      state
    )
  end

  describe "a body the parser cannot handle" do
    test "survives every truncation, rather than the ones we thought of" do
      # 0..96 spans empty, short-of-Header, mid-frame_id, the 22-23 byte
      # window that made `binary_part/3` negative, and past a full
      # 72-byte TwistStamped.
      state = state(TwistStamped)

      for size <- 0..96, filler <- [0x00, 0xAB, 0xFF] do
        body = :binary.copy(<<filler>>, size)

        capture_log(fn ->
          assert {:noreply, ^state} = sample(state, body),
                 "a #{size}-byte body of #{filler} killed the client"
        end)
      end
    end

    test "the length that used to raise ArgumentError" do
      # Header parses, `rest` is 0-3 bytes, consumed lands on 17..20, so
      # padding is 4..7 and the length passed to `binary_part/3` goes
      # negative.
      state = state(TwistStamped)

      for size <- 21..24 do
        log =
          capture_log(fn ->
            assert {:noreply, ^state} = sample(state, :binary.copy(<<0>>, size))
          end)

        assert log =~ "failed"
      end
    end

    test "says which module and topic, so the mismatch is findable" do
      log = capture_log(fn -> sample(state(TwistStamped), <<>>) end)

      assert log =~ "TwistStamped"
      assert log =~ "cmd_vel_nav"
    end

    test "delivers nothing to the subscriber" do
      capture_log(fn -> sample(state(TwistStamped), :binary.copy(<<0xAB>>, 30)) end)
      refute_received {:ros_message, _}
    end
  end

  describe "a body the parser handles but should not have" do
    test "warns about surplus bytes, which is the only sign of the wrong type" do
      # Nav2's `enable_stamped_cmd_vel` defaults to true, so subscribing
      # with `message: Twist` gets a 72-byte TwistStamped body.
      # `Twist.parse/1` accepts anything >= 48 bytes: it reads the
      # header's bytes as float64s and succeeds, yielding denormals near
      # 1.0e-273. The vehicle then ignores every planner command while
      # both watchdogs report a healthy stream -- so the leftover bytes
      # are the whole diagnosis.
      log =
        capture_log(fn ->
          assert {:noreply, _} = sample(state(Twist), :binary.copy(<<0>>, 72))
        end)

      assert log =~ "24 bytes unread"
      assert log =~ "different message type"

      # It did parse, so the message still goes through: this is a
      # diagnostic, not a filter. Dropping it would be a second policy
      # to reason about, and a wrong-type publisher is a bring-up
      # mistake to be told about rather than something to paper over.
      assert_received {:ros_message, {_key, %Twist{}}}
    end

    test "trailing alignment padding is not a mismatch" do
      # Messages ending in a variable-length field -- `Joy`'s axes and
      # buttons, `CompressedImage`'s data -- can carry CDR padding after
      # the last element, up to 7 bytes for the widest primitive. Below
      # the threshold nothing is said, or every camera frame would warn
      # every 5 seconds for ever.
      for surplus <- 1..7 do
        log =
          capture_log(fn ->
            assert {:noreply, _} = sample(state(Twist), :binary.copy(<<0>>, 48 + surplus))
          end)

        assert log == "", "#{surplus} bytes of padding was reported as a mismatch"
      end
    end

    test "one byte past what padding can explain is a mismatch" do
      log =
        capture_log(fn ->
          assert {:noreply, _} = sample(state(Twist), :binary.copy(<<0>>, 48 + 8))
        end)

      assert log =~ "8 bytes unread"
    end

    test "a well-formed body of the right type warns about nothing" do
      body = :binary.copy(<<0>>, 48)
      log = capture_log(fn -> assert {:noreply, _} = sample(state(Twist), body) end)

      assert log == ""
      assert_received {:ros_message, {_key, %Twist{}}}
    end
  end
end

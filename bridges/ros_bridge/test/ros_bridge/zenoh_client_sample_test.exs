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
  error, and the client has to survive the raise as well.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias RosBridge.ZenohClient
  alias RosBridge.ZenohClient.State
  alias Ros2.GeometryMsgs.Msg.{Twist, TwistStamped}

  @key "0/cmd_vel_nav/**"
  # rmw_zenoh's CDR header: little-endian, no options.
  @cdr_header <<0x00, 0x01, 0x00, 0x00>>

  defp client_state(message_module) do
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

  defp deliver_sample(state, body) do
    ZenohClient.handle_info(
      %Zenohex.Sample{key_expr: "0/cmd_vel_nav/msg", payload: @cdr_header <> body},
      state
    )
  end

  describe "a body the parser cannot handle" do
    test "survives a truncation at every length" do
      # 0..96 spans empty, short-of-Header, mid-frame_id, the 22-23 byte
      # window where the `binary_part/3` length goes negative, and past a
      # full 72-byte TwistStamped.
      state = client_state(TwistStamped)

      for size <- 0..96, filler <- [0x00, 0xAB, 0xFF] do
        body = :binary.copy(<<filler>>, size)

        capture_log(fn ->
          assert {:noreply, ^state} = deliver_sample(state, body),
                 "a #{size}-byte body of #{filler} killed the client"
        end)
      end
    end

    test "a length whose padding makes the binary_part/3 length negative" do
      # Header parses, `rest` is 0-3 bytes, consumed lands on 17..20, so
      # padding is 4..7 and the length passed to `binary_part/3` goes
      # negative.
      state = client_state(TwistStamped)

      for size <- 21..24 do
        log =
          capture_log(fn ->
            assert {:noreply, ^state} = deliver_sample(state, :binary.copy(<<0>>, size))
          end)

        assert log =~ "failed"
      end
    end

    test "says which module and topic, so the mismatch is findable" do
      log = capture_log(fn -> deliver_sample(client_state(TwistStamped), <<>>) end)

      assert log =~ "TwistStamped"
      assert log =~ "cmd_vel_nav"
    end

    test "delivers nothing to the subscriber" do
      capture_log(fn ->
        deliver_sample(client_state(TwistStamped), :binary.copy(<<0xAB>>, 30))
      end)

      refute_received {:ros_message, _}
    end
  end

  describe "a body the parser handles but should not have" do
    test "warns about surplus bytes, which is the only sign of the wrong type" do
      # Nav2 publishes TwistStamped by default, and `Twist.parse/1` reads
      # its 72 bytes as near-zero float64s and succeeds, so the leftover
      # bytes are the only sign of the wrong type.
      log =
        capture_log(fn ->
          assert {:noreply, _} = deliver_sample(client_state(Twist), :binary.copy(<<0>>, 72))
        end)

      assert log =~ "24 bytes unread"
      assert log =~ "different message type"

      # It parsed, so it is still delivered: a diagnostic, not a filter.
      assert_received {:ros_message, {_key, %Twist{}}}
    end

    test "trailing alignment padding is not a mismatch" do
      # Messages ending in a variable-length field (`Joy`, `CompressedImage`)
      # can carry CDR padding after the last element, up to 7 bytes for
      # the widest primitive.
      for surplus <- 1..7 do
        log =
          capture_log(fn ->
            assert {:noreply, _} =
                     deliver_sample(client_state(Twist), :binary.copy(<<0>>, 48 + surplus))
          end)

        # Other async tests log too: only the surplus warning is ruled out.
        refute log =~ "unread", "#{surplus} bytes of padding was reported as a mismatch"
      end
    end

    test "one byte past what padding can explain is a mismatch" do
      log =
        capture_log(fn ->
          assert {:noreply, _} = deliver_sample(client_state(Twist), :binary.copy(<<0>>, 48 + 8))
        end)

      assert log =~ "8 bytes unread"
    end

    test "a well-formed body of the right type warns about nothing" do
      body = :binary.copy(<<0>>, 48)

      log =
        capture_log(fn -> assert {:noreply, _} = deliver_sample(client_state(Twist), body) end)

      # Other async tests log too, so only the surplus warning is ruled
      # out, not every line captured in the window.
      refute log =~ "unread"
      assert_received {:ros_message, {_key, %Twist{}}}
    end
  end
end

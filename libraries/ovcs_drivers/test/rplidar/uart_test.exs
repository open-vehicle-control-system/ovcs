defmodule RPLidar.UARTTest do
  use ExUnit.Case, async: true
  import Bitwise

  # A standard-scan node: angle in degrees clockwise, distance in mm.
  defp node(start?, angle_degrees, distance_mm, quality) do
    angle_q6 = round(angle_degrees * 64)
    s = if start?, do: 1, else: 0

    <<quality <<< 2 ||| (1 - s) <<< 1 ||| s, (angle_q6 &&& 0x7F) <<< 1 ||| 1, angle_q6 >>> 7,
      round(distance_mm * 4)::little-16>>
  end

  describe "parse_nodes/1" do
    test "decodes nodes into ROS angles, metres and quality, keeping a partial node" do
      buffer = node(true, 90, 1000, 47) <> node(false, 0, 0, 0) <> <<1, 2, 3>>
      {[first, second], rest} = RPLidar.UART.parse_nodes(buffer)

      {true, angle, 1.0, 47} = first
      assert_in_delta angle, 3 * :math.pi() / 2, 1.0e-9
      assert second == {false, 0.0, 0.0, 0}
      assert rest == <<1, 2, 3>>
    end

    test "skips bytes until the check bits line up" do
      {[{false, _, distance, 10}], <<>>} =
        RPLidar.UART.parse_nodes(<<0xFF>> <> node(false, 45, 2500, 10))

      assert distance == 2.5
    end
  end

  describe "parse_response/3" do
    test "returns the payload after its descriptor, and what follows" do
      descriptor = <<0xA5, 0x5A, 3, 0, 0, 0, 0x06>>

      assert RPLidar.UART.parse_response(<<0x00>> <> descriptor <> <<0, 0, 0, 9>>, 0x06, 3) ==
               {:ok, <<0, 0, 0>>, <<9>>}
    end

    test "waits for the whole payload" do
      assert RPLidar.UART.parse_response(<<0xA5, 0x5A, 3, 0, 0, 0, 0x06, 0>>, 0x06, 3) == :more
    end
  end
end

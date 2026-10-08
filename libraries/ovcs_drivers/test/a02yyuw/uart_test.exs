defmodule A02YYUW.UARTTest do
  use ExUnit.Case, async: true

  defp frame(millimetres) do
    high = div(millimetres, 256)
    low = rem(millimetres, 256)
    <<0xFF, high, low, rem(0xFF + high + low, 256)>>
  end

  describe "parse_frames/1" do
    test "decodes valid frames and keeps a partial one" do
      assert A02YYUW.UART.parse_frames(frame(1234) <> frame(30) <> <<0xFF, 4>>) ==
               {[1234, 30], <<0xFF, 4>>}
    end

    test "skips bytes until a frame's checksum holds" do
      assert A02YYUW.UART.parse_frames(<<0x12, 0xFF, 1, 2, 9>> <> frame(4500)) == {[4500], <<>>}
    end
  end

  describe "a received frame" do
    defp receive_frame(millimetres) do
      state = %{listeners: [self()], buffer: <<>>, range: {0.03, 4.5}, field_of_view: 1.0}

      {:noreply, _} =
        A02YYUW.UART.handle_info({:circuits_uart, "ttyUSB1", frame(millimetres)}, state)

      assert_receive {:"$gen_cast", {:range_sample, sample}}
      sample.distance
    end

    test "is a distance in metres, or out of range" do
      assert receive_frame(1234) == 1.234
      assert receive_frame(20) == :below_range
      assert receive_frame(4600) == :beyond_range
    end

    test "of 0, no echo, is nothing in range" do
      assert receive_frame(0) == :beyond_range
    end
  end

  describe "OvcsDrivers.Serial.find/2" do
    test "names the adapter with that serial number" do
      devices = %{
        "ttyUSB0" => %{serial_number: "aa"},
        "ttyUSB1" => %{serial_number: "bb"},
        "ttyS0" => %{}
      }

      assert OvcsDrivers.Serial.find(devices, "bb") == {:ok, "ttyUSB1"}
      assert {:error, "no serial adapter" <> _} = OvcsDrivers.Serial.find(devices, "cc")
    end
  end
end

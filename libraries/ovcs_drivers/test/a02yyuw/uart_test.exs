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

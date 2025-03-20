defmodule VmsCore.Components.Nissan.Util do
  @moduledoc """
   Nissan AZE0 CAN utils
  """
  import Bitwise

  def crc8(raw_data) do
    CRC.calculate(
      raw_data,
      %{
        width: 8,
        poly: 0x85,
        init: 0x00,
        refin: false,
        refout: false,
        xorout: 0x00
      }
    )
  end

  def counter(value) do
    rem(value, 4)
  end

  def shifted_counter(value) do
    bxor(7, counter(value) <<< 6)
  end
end

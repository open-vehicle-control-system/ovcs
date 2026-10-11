defmodule VmsCore.Components.Nissan.FrameIntegrity do
  @moduledoc """
  Frame helpers shared by the Nissan Leaf AZE0 drivers: the CRC and the
  rolling counters their frames carry.
  """
  import Bitwise

  @doc "The CRC-8 (polynomial 0x85) closing a Nissan frame, over its payload."
  def crc8(payload) do
    CRC.calculate(
      payload,
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

  @doc "The 2-bit rolling counter for a frame count."
  def counter(frame_count) do
    rem(frame_count, 4)
  end

  @doc "The rolling counter in the top two bits of a byte whose low bits are 7."
  def shifted_counter(frame_count) do
    bxor(7, counter(frame_count) <<< 6)
  end
end

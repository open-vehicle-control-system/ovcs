defmodule NervesTime.RealTimeClock.BCD do
  @moduledoc """
  Convert between integers and binary-coded decimals (BCD)

  BCD is commonly used in Real-time clock chips for historical reasons. See
  [wikipedia.org/wiki/Binary-coded_decimal](https://en.wikipedia.org/wiki/Binary-coded_decimal)
  for a good background on BCD. The BCD implementation here is referred to as
  "Packed BCD" in the article.
  """

  @typedoc """
  Support two digit BCD
  """
  @type t() ::
          0x00..0x09
          | 0x10..0x19
          | 0x20..0x29
          | 0x30..0x39
          | 0x40..0x49
          | 0x50..0x59
          | 0x60..0x69
          | 0x70..0x79
          | 0x80..0x89
          | 0x90..0x99

  @doc "Convert a 8 bit integer value to a BCD binary"
  @spec from_integer(0..99) :: t()
  def from_integer(value) when value >= 0 and value <= 99 do
    tens = div(value, 10)
    units = rem(value, 10)
    16 * tens + units
  end

  @doc "Convert an 8 bit bcd-encoded value to an integer"
  @spec to_integer(t()) :: 0..99
  def to_integer(value) when value >= 0 and value <= 0x99 do
    tens = div(value, 16)
    units = rem(value, 16)
    10 * tens + units
  end
end

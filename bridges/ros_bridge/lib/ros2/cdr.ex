defmodule Ros2.Cdr do
  @moduledoc """
  Little-endian CDR (XCDR1) for nested ROS 2 types, aligned on the
  absolute offset in the message, which is what nested structures and
  sequences need.

  Encoders append to the message built so far, so `byte_size/1` of the
  accumulator is the offset. Decoders take and return `{rest, offset}`
  and return `{value, {rest, offset}}`. Both start at offset 0, after
  the encapsulation header.
  """

  def pad(message, alignment),
    do:
      message <>
        :binary.copy(<<0>>, rem(alignment - rem(byte_size(message), alignment), alignment))

  def u8(message, value), do: message <> <<value::8>>
  def bool(message, value), do: u8(message, if(value, do: 1, else: 0))
  def u32(message, value), do: pad(message, 4) <> <<value::little-32>>
  def i64(message, value), do: pad(message, 8) <> <<value::little-signed-64>>
  def u64(message, value), do: pad(message, 8) <> <<value::little-64>>
  def f64(message, value), do: pad(message, 8) <> <<value * 1.0::little-float-64>>

  @doc """
  A `float32`. `:infinity` and `:neg_infinity` encode the IEEE
  infinities, which Elixir floats lack and REP 117 range sensors need.
  """
  def f32(message, :infinity), do: pad(message, 4) <> <<0x7F800000::little-32>>
  def f32(message, :neg_infinity), do: pad(message, 4) <> <<0xFF800000::little-32>>
  def f32(message, value), do: pad(message, 4) <> <<value * 1.0::little-float-32>>

  def string(message, string), do: u32(message, byte_size(string) + 1) <> string <> <<0>>

  @doc "A sequence: its length, then each element through `encode`."
  def sequence(message, list, encode),
    do: Enum.reduce(list, u32(message, length(list)), &encode.(&2, &1))

  def skip_pad({binary, offset}, alignment) do
    padding_size = rem(alignment - rem(offset, alignment), alignment)
    <<_::binary-size(padding_size), rest::binary>> = binary
    {rest, offset + padding_size}
  end

  def read_u8({<<byte::8, rest::binary>>, offset}), do: {byte, {rest, offset + 1}}

  def read_bool(input) do
    {byte, input} = read_u8(input)
    {byte != 0, input}
  end

  def read_u32(input) do
    {<<value::little-32, rest::binary>>, offset} = skip_pad(input, 4)
    {value, {rest, offset + 4}}
  end

  def read_i64(input) do
    {<<value::little-signed-64, rest::binary>>, offset} = skip_pad(input, 8)
    {value, {rest, offset + 8}}
  end

  def read_u64(input) do
    {<<value::little-64, rest::binary>>, offset} = skip_pad(input, 8)
    {value, {rest, offset + 8}}
  end

  def read_f64(input) do
    {<<value::little-float-64, rest::binary>>, offset} = skip_pad(input, 8)
    {value, {rest, offset + 8}}
  end

  def read_string(input) do
    {size_with_null, {binary, offset}} = read_u32(input)
    <<string::binary-size(size_with_null - 1), 0, rest::binary>> = binary
    {string, {rest, offset + size_with_null}}
  end

  @doc "A sequence: its length, then that many elements through `decode`."
  def read_sequence(input, decode) do
    {count, input} = read_u32(input)

    {reversed_elements, input} =
      Enum.reduce(1..count//1, {[], input}, fn _, {elements, input} ->
        {element, input} = decode.(input)
        {[element | elements], input}
      end)

    {Enum.reverse(reversed_elements), input}
  end
end

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

  # ── encoding ─────────────────────────────────────────────────

  def pad(acc, n), do: acc <> :binary.copy(<<0>>, rem(n - rem(byte_size(acc), n), n))

  def u8(acc, v), do: acc <> <<v::8>>
  def bool(acc, v), do: u8(acc, if(v, do: 1, else: 0))
  def u32(acc, v), do: pad(acc, 4) <> <<v::little-32>>
  def i64(acc, v), do: pad(acc, 8) <> <<v::little-signed-64>>
  def u64(acc, v), do: pad(acc, 8) <> <<v::little-64>>
  def f64(acc, v), do: pad(acc, 8) <> <<v * 1.0::little-float-64>>
  def f32(acc, v), do: pad(acc, 4) <> <<v * 1.0::little-float-32>>
  def string(acc, s), do: u32(acc, byte_size(s) + 1) <> s <> <<0>>

  @doc "A sequence: its length, then each element through `encode`."
  def sequence(acc, list, encode), do: Enum.reduce(list, u32(acc, length(list)), &encode.(&2, &1))

  # ── decoding ─────────────────────────────────────────────────

  def skip_pad({bin, offset}, n) do
    p = rem(n - rem(offset, n), n)
    <<_::binary-size(p), rest::binary>> = bin
    {rest, offset + p}
  end

  def read_u8({<<v::8, rest::binary>>, offset}), do: {v, {rest, offset + 1}}

  def read_bool(input) do
    {v, input} = read_u8(input)
    {v != 0, input}
  end

  def read_u32(input) do
    {<<v::little-32, rest::binary>>, offset} = skip_pad(input, 4)
    {v, {rest, offset + 4}}
  end

  def read_i64(input) do
    {<<v::little-signed-64, rest::binary>>, offset} = skip_pad(input, 8)
    {v, {rest, offset + 8}}
  end

  def read_u64(input) do
    {<<v::little-64, rest::binary>>, offset} = skip_pad(input, 8)
    {v, {rest, offset + 8}}
  end

  def read_f64(input) do
    {<<v::little-float-64, rest::binary>>, offset} = skip_pad(input, 8)
    {v, {rest, offset + 8}}
  end

  def read_string(input) do
    {n, {bin, offset}} = read_u32(input)
    <<s::binary-size(n - 1), 0, rest::binary>> = bin
    {s, {rest, offset + n}}
  end

  @doc "A sequence: its length, then that many elements through `decode`."
  def read_sequence(input, decode) do
    {n, input} = read_u32(input)

    {items, input} =
      Enum.reduce(1..n//1, {[], input}, fn _, {acc, input} ->
        {item, input} = decode.(input)
        {[item | acc], input}
      end)

    {Enum.reverse(items), input}
  end
end

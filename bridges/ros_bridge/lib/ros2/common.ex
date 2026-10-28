# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
# The quote is the module: splitting it would export the private parsers.
defmodule Ros2.Common do
  @moduledoc """
  CDR (Common Data Representation) encoder/parser primitives shared
  by every `Ros2.*` message module. Injected via `use Ros2.Common`.

  ## Alignment

  CDR aligns each primitive to its own size, relative to the start of
  the encapsulated body (i.e. after the 4-byte encapsulation header
  prepended by `Ros2.RmwZenoh.encode_payload/1`). Since each
  `encode/1` returns the body bytes only, `byte_size(buffer)` *is*
  the current offset from the body origin — call `align_to/2` before
  the next primitive whose alignment is larger than the running tail.

  The hazards in the message set:

    * `string` (4-aligned tail) → `float64` field needs an
      `align_to(buffer, 8)` step in between.
    * `int32`/`uint32` (4) → `float64` (8) needs `align_to(buffer, 8)`.

  Within a homogeneous `float64` sequence (e.g. covariance matrices)
  no extra alignment is needed once the run starts on an 8-boundary.

  The encoders return the field bytes only; callers call `align_to/2`
  before fields whose alignment is larger than the running buffer tail.
  The exceptions, `append_float64_sequence/2` and `align_to/2`, take the
  in-progress body buffer, because their padding depends on where the
  field lands.
  """

  defmacro __using__(_opts) do
    quote do
      @doc """
      CDR string: 4-byte LE length (including the trailing null), the
      bytes and null, then zero padding to the next 4-byte boundary so a
      following u32-or-larger field lands aligned, as rclpy and
      rmw_zenoh emit it.

      When the next field is a u8 (e.g. `sensor_msgs/Image.is_bigendian`)
      this over-pads: use `encode_string_unaligned/1` and `align_to/2`.
      """
      def encode_string(string) when is_binary(string) do
        bytes = string <> <<0>>
        size_with_null = byte_size(bytes)
        padding_size = rem(4 - rem(4 + size_with_null, 4), 4)

        <<size_with_null::little-unsigned-integer-size(32), bytes::binary,
          0::size(padding_size * 8)>>
      end

      @doc """
      Standards-strict CDR string: 4-byte LE length and the bytes
      (including null), no trailing padding. Use it when the next field
      has alignment below 4 (typically `uint8`), where the padding of
      `encode_string/1` would shift every following field.
      """
      def encode_string_unaligned(string) when is_binary(string) do
        bytes = string <> <<0>>
        size_with_null = byte_size(bytes)
        <<size_with_null::little-unsigned-integer-size(32), bytes::binary>>
      end

      def parse_string(
            <<size_with_null::little-unsigned-integer-size(32),
              string::binary-size(size_with_null), payload::binary>>
          ) do
        total_size = 4 + size_with_null
        padding = rem(4 - rem(total_size, 4), 4)

        payload =
          case byte_size(payload) do
            size when size > padding ->
              <<_padding::binary-size(^padding), payload::binary>> = payload
              payload

            _ ->
              payload
          end

        {:ok, string |> String.trim_trailing(<<0>>), payload}
      rescue
        _ -> {:error, :malformed, :string}
      end

      # Fixed-size `float64[count]`: CDR omits the length prefix.
      defp parse_float64_array(payload, count) do
        <<floats::binary-size(^count * 8), payload::binary>> = payload
        array = for <<element::little-signed-float-size(64) <- floats>>, do: element
        {:ok, array, payload}
      rescue
        _ -> {:error, :malformed, :float64_array}
      end

      defp parse_float32_array(<<count::little-integer-size(32), payload::binary>>) do
        <<floats::binary-size(^count * 4), payload::binary>> = payload
        array = for <<element::little-signed-float-size(32) <- floats>>, do: element
        {:ok, array, payload}
      rescue
        _ -> {:error, :malformed, :float32_array}
      end

      defp parse_int32_array(<<count::little-unsigned-integer-size(32), payload::binary>>) do
        <<integers::binary-size(^count * 4), payload::binary>> = payload
        array = for <<element::little-signed-integer-size(32) <- integers>>, do: element
        {:ok, array, payload}
      rescue
        _ -> {:error, :malformed, :int32_array}
      end

      def encode_int32(value) when is_integer(value) do
        <<value::little-signed-integer-size(32)>>
      end

      def encode_uint32(value) when is_integer(value) do
        <<value::little-unsigned-integer-size(32)>>
      end

      def encode_float64(value) when is_number(value) do
        <<value::little-float-size(64)>>
      end

      @doc "Fixed-size `float64[count]`, no length prefix. Mirrors `parse_float64_array/2`."
      def encode_float64_array_fixed(values, count) when length(values) == count do
        Enum.reduce(values, <<>>, fn value, acc -> acc <> encode_float64(value) end)
      end

      def encode_uint8(value) when is_integer(value) do
        <<value::little-unsigned-integer-size(8)>>
      end

      def encode_uint16(value) when is_integer(value) do
        <<value::little-unsigned-integer-size(16)>>
      end

      def encode_float32(value) when is_number(value) do
        <<value::little-float-size(32)>>
      end

      def encode_bool(true), do: <<1::little-unsigned-integer-size(8)>>
      def encode_bool(false), do: <<0::little-unsigned-integer-size(8)>>

      @doc """
      Unbounded `uint8[]`: 4-byte LE length prefix, then the raw bytes.
      No trailing padding, since a u8 has alignment 1.
      """
      def encode_byte_sequence(bytes) when is_binary(bytes) do
        <<byte_size(bytes)::little-unsigned-integer-size(32), bytes::binary>>
      end

      @doc """
      Appends an unbounded `float64[]` to the in-progress body `buffer`:
      the 4-byte LE length prefix, then the floats 8-aligned.

      It takes the buffer because the padding depends on where the prefix
      lands: a `frame_id` of 11 or 12 characters moves the prefix between
      the two 8-residues, needing 4 bytes of padding in one case and 0 in
      the other. An empty sequence is just the prefix, as Fast-CDR's
      `serialize_array` returns before aligning when the count is 0.
      """
      def append_float64_sequence(buffer, values)
          when is_binary(buffer) and is_list(values) do
        buffer = buffer <> <<length(values)::little-unsigned-integer-size(32)>>

        case values do
          [] ->
            buffer

          _ ->
            Enum.reduce(values, align_to(buffer, 8), fn value, acc ->
              acc <> encode_float64(value)
            end)
        end
      end

      @doc """
      Unbounded sequence of an inner CDR struct: the u32 element count,
      then `encode_one` (returning one element's body bytes) applied to
      each value. Alignment between elements is the caller's.
      """
      def encode_struct_sequence(values, encode_one)
          when is_list(values) and is_function(encode_one, 1) do
        prefix = <<length(values)::little-unsigned-integer-size(32)>>
        body = Enum.reduce(values, <<>>, fn value, acc -> acc <> encode_one.(value) end)
        prefix <> body
      end

      @doc """
      Pads the in-progress body `buffer` with zero bytes until its size
      is a multiple of `alignment`. The origin is the start of the
      encapsulated body.
      """
      def align_to(buffer, alignment)
          when is_binary(buffer) and is_integer(alignment) and alignment > 0 do
        padding_size = rem(alignment - rem(byte_size(buffer), alignment), alignment)
        buffer <> <<0::size(padding_size * 8)>>
      end

      # Inverse of `append_float64_sequence/2`; `body_size` anchors the offset.
      defp parse_float64_sequence(payload, body_size) when is_integer(body_size) do
        case payload do
          <<count::little-unsigned-integer-size(32), rest::binary>> ->
            offset_after_prefix = body_size - byte_size(payload) + 4
            take_float64_run(rest, count, offset_after_prefix)

          _ ->
            {:error, :malformed, :float64_sequence}
        end
      end

      defp take_float64_run(rest, 0, _offset), do: {:ok, [], rest}

      defp take_float64_run(rest, count, offset) do
        padding_size = rem(8 - rem(offset, 8), 8)
        bytes_needed = count * 8

        case rest do
          <<_padding::binary-size(^padding_size), floats::binary-size(^bytes_needed),
            tail::binary>> ->
            values = for <<element::little-signed-float-size(64) <- floats>>, do: element
            {:ok, values, tail}

          _ ->
            {:error, :malformed, :float64_sequence}
        end
      end

      # `current_offset` is measured from the body origin.
      defp consume_alignment(payload, alignment, current_offset) do
        padding_size = rem(alignment - rem(current_offset, alignment), alignment)
        <<_skip::binary-size(^padding_size), rest::binary>> = payload
        rest
      end
    end
  end
end

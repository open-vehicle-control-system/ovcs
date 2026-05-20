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

  The hazards in our message set:

    * `string` (4-aligned tail) → `float64` field needs an
      `align_to(buf, 8)` step in between.
    * `int32`/`uint32` (4) → `float64` (8) needs `align_to(buf, 8)`.

  Within a homogenous `float64` sequence (e.g. covariance matrices)
  no extra alignment is needed once the run starts on an 8-boundary.
  """

  defmacro __using__(_opts) do
    quote do
      # CDR encoder for strings: 4-byte LE length (including the
      # trailing null byte), then the bytes + null, then 0-padding
      # to the next 4-byte boundary so a following u32-or-larger
      # field lands aligned. This matches what rclpy / rmw_zenoh
      # emit on the wire for the *common* case where the next
      # field is u32.
      #
      # If the next field is u8 (alignment 1, e.g.
      # `sensor_msgs/Image.is_bigendian`), this over-pads — use
      # `encode_string_unaligned/1` instead and let the caller
      # handle alignment via `align_to/2`.
      def encode_string(str) when is_binary(str) do
        bytes = str <> <<0>>
        len = byte_size(bytes)
        pad_size = rem(4 - rem(4 + len, 4), 4)
        <<len::little-unsigned-integer-size(32), bytes::binary, 0::size(pad_size * 8)>>
      end

      # Standards-strict CDR string: 4-byte LE length + bytes
      # (including null), no trailing padding. Use when the next
      # field has alignment < 4 (typically `uint8`) — the over-
      # padding `encode_string/1` performs would otherwise shift
      # subsequent fields out of position on the receiver.
      def encode_string_unaligned(str) when is_binary(str) do
        bytes = str <> <<0>>
        len = byte_size(bytes)
        <<len::little-unsigned-integer-size(32), bytes::binary>>
      end

      def parse_string(<<len::little-unsigned-integer-size(32), string::binary-size(len), payload::binary>>) do
        # Calculate padding to align to 4-byte boundary
        total_size = 4 + len
        padding = rem(4 - rem(total_size, 4), 4)

        payload = case byte_size(payload) do
          size when size > padding ->
            <<_padding::binary-size(padding), payload::binary>> = payload
            payload
          _ ->
            payload
        end
        {:ok, string |> String.trim_trailing(<<0>>), payload}
      rescue
        _ -> {:error, :malformed, :string}
      end

      # Fixed-size `float64[N]` array — CDR omits the length prefix
      # for bounded arrays, so the caller passes the element count.
      # For an unbounded `float64[]` we'd need a separate parser that
      # reads the leading u32 length first.
      defp parse_float64_array(payload, count) do
        <<floats::binary-size(count * 8), payload::binary>> = payload
        array = for <<element::little-signed-float-size(64) <- floats>>, do: element
        {:ok, array, payload}
      rescue
        _ -> {:error, :malformed, :float64_array}
      end

      defp parse_float32_array(<<len::little-integer-size(32), payload::binary>>) do
        <<floats::binary-size(len * 4), payload::binary>> = payload
        array = for <<element::little-signed-float-size(32) <- floats>>, do: element
        {:ok, array, payload}
      rescue
        _ -> {:error, :malformed, :float32_array}
      end

      defp parse_int32_array(<<len::little-unsigned-integer-size(32), payload::binary>>) do
        <<ints::binary-size(len * 4), payload::binary>> = payload
        array = for <<element::little-signed-integer-size(32) <- ints>>, do: element
        {:ok, array, payload}
      rescue
        _ -> {:error, :malformed, :int32_array}
      end

      # ── Encoders for primitive types ──────────────────────────────
      # Each returns the field bytes only. Callers are responsible for
      # invoking `align_to/2` before fields whose alignment is larger
      # than the running buffer tail.

      def encode_int32(value) when is_integer(value) do
        <<value::little-signed-integer-size(32)>>
      end

      def encode_uint32(value) when is_integer(value) do
        <<value::little-unsigned-integer-size(32)>>
      end

      def encode_float64(value) when is_number(value) do
        <<value::little-float-size(64)>>
      end

      # Fixed-size `float64[count]` — no length prefix. Mirrors
      # `parse_float64_array/2`.
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

      # Unbounded `uint8[]` (≈ CDR sequence of octets) — 4-byte LE
      # length prefix followed by the raw bytes. No trailing padding
      # required since the alignment of a u8 is 1.
      def encode_byte_sequence(bytes) when is_binary(bytes) do
        <<byte_size(bytes)::little-unsigned-integer-size(32), bytes::binary>>
      end

      # Unbounded `float64[]` — 4-byte LE length prefix, 4-byte
      # padding to reach 8-alignment (the caller must have already
      # placed the prefix on a 4-aligned offset, which is the
      # natural state since u32 is 4-aligned), then the run.
      def encode_float64_sequence(values) when is_list(values) do
        prefix = <<length(values)::little-unsigned-integer-size(32)>>
        # The prefix is 4 bytes; align to 8 before the float run.
        # We do this relative to a hypothetical body where the prefix
        # has just been appended — i.e. add 4 bytes of padding.
        body =
          Enum.reduce(values, <<>>, fn value, acc -> acc <> encode_float64(value) end)

        prefix <> <<0::size(4 * 8)>> <> body
      end

      # Unbounded sequence of an inner CDR struct. `encode_one` is a
      # 1-arg function returning the inner struct's body bytes; this
      # helper prepends the u32 element count and concatenates the
      # results. The caller is responsible for any alignment between
      # successive elements when needed (most nested message types
      # naturally land on their own alignment).
      def encode_struct_sequence(values, encode_one)
          when is_list(values) and is_function(encode_one, 1) do
        prefix = <<length(values)::little-unsigned-integer-size(32)>>
        body = Enum.reduce(values, <<>>, fn value, acc -> acc <> encode_one.(value) end)
        prefix <> body
      end

      # Append zero-byte padding so `byte_size(buffer)` becomes a
      # multiple of `n`. Pure — takes the in-progress body buffer,
      # returns the padded buffer. See moduledoc for the alignment
      # contract (origin = start of encapsulated body).
      def align_to(buffer, n) when is_binary(buffer) and is_integer(n) and n > 0 do
        pad = rem(n - rem(byte_size(buffer), n), n)
        buffer <> <<0::size(pad * 8)>>
      end
    end
  end
end

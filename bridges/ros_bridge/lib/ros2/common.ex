# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
# The quote block *is* the module: `use Ros2.Common` injects the shared
# CDR codec into each `Ros2.*` message module, several of which need the
# parsers as private functions. Splitting it to satisfy the length check
# would mean either exporting every codec or nesting sub-macros, both of
# which read worse than one documented block.
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

      def parse_string(
            <<len::little-unsigned-integer-size(32), string::binary-size(len), payload::binary>>
          ) do
        # Calculate padding to align to 4-byte boundary
        total_size = 4 + len
        padding = rem(4 - rem(total_size, 4), 4)

        payload =
          case byte_size(payload) do
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

      # Unbounded `float64[]` — 4-byte LE length prefix, then the
      # float run 8-aligned. Takes the in-progress body buffer rather
      # than returning standalone bytes: the padding depends on where
      # the prefix actually lands, which only the buffer knows. A
      # field-only version cannot be correct — e.g. a `frame_id` of
      # 11 vs 12 characters shifts the prefix between the two
      # 8-residues, needing 4 bytes of padding in one case and 0 in
      # the other.
      #
      # An empty sequence gets no padding at all: Fast-CDR's
      # `serialize_array` returns before aligning when the element
      # count is 0, so a `float64[]` of length 0 is just the prefix.
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

      # Unbounded `float64[]` parser. Inverse of
      # `append_float64_sequence/2`, and it needs the same offset
      # information the encoder had: `body_size` is the size of the
      # full encapsulated body, so `body_size - byte_size(payload)`
      # is the current offset from the body origin. A fixed padding
      # skip cannot be correct for the same reason the encoder's
      # couldn't. Zero-length sequences carry no padding.
      defp parse_float64_sequence(payload, body_size) when is_integer(body_size) do
        case payload do
          <<len::little-unsigned-integer-size(32), rest::binary>> ->
            offset_after_prefix = body_size - byte_size(payload) + 4
            take_float64_run(rest, len, offset_after_prefix)

          _ ->
            {:error, :malformed, :float64_sequence}
        end
      end

      defp take_float64_run(rest, 0, _offset), do: {:ok, [], rest}

      defp take_float64_run(rest, len, offset) do
        pad = rem(8 - rem(offset, 8), 8)
        bytes_needed = len * 8

        case rest do
          <<_pad::binary-size(pad), floats::binary-size(bytes_needed), tail::binary>> ->
            values = for <<v::little-signed-float-size(64) <- floats>>, do: v
            {:ok, values, tail}

          _ ->
            {:error, :malformed, :float64_sequence}
        end
      end

      # Strip `n` bytes of alignment padding given the current offset
      # from the body origin. Used by parsers that need to skip CDR
      # padding between fields of differing alignment.
      defp consume_alignment(payload, alignment, current_offset) do
        pad = rem(alignment - rem(current_offset, alignment), alignment)
        <<_skip::binary-size(pad), rest::binary>> = payload
        rest
      end
    end
  end
end

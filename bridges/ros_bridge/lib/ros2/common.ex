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
      # trailing null byte), then the bytes + null, then 0-padding to
      # the next 4-byte boundary so the next field aligns. Producing
      # the trailing padding even when this is the last field is
      # harmless and keeps the encoder composable.
      def encode_string(str) when is_binary(str) do
        bytes = str <> <<0>>
        len = byte_size(bytes)
        pad_size = rem(4 - rem(4 + len, 4), 4)
        <<len::little-unsigned-integer-size(32), bytes::binary, 0::size(pad_size * 8)>>
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

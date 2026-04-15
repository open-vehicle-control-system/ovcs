defmodule Ros2.Common do
  defmacro __using__(_opts) do
    quote do
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

      defp parse_float64_array(<<payload::binary>>) do
        # len |> IO.inspect(label: "LEN FLOAT")
        len =9
        <<floats::binary-size(len * 8), payload::binary>> = payload
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
    end
  end
end

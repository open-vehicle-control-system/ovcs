defmodule VintageNetWiFi.WPSData do
  @moduledoc """
  Utilities for handling WPS data
  """

  @typedoc """
  A map containing WPS data

  All keys are optional. Known keys use atoms. Unknown keys use their numeric
  value and their value is left as a raw binary.

  Known keys:

  * `:credential` - a map of WiFi credentials (also WPS data)
  * `:mac_address` - a MAC address in string form (i.e., `"aa:bb:cc:dd:ee:ff"`)
  * `:network_key` - a passphrase or PSK
  * `:network_index` - the key index
  """
  @type t() :: %{
          optional(:credential) => t(),
          optional(:mac_address) => binary(),
          optional(:network_key) => binary(),
          optional(:network_index) => non_neg_integer(),
          optional(0..65536) => binary()
        }

  @doc """
  Decode WPS data

  The WPS data is expected to be in hex string form like what the
  wpa_supplicant reports.
  """
  @spec decode(binary) :: {:ok, t()} | :error
  def decode(hex_string) when is_binary(hex_string) do
    with {:ok, raw_bytes} <- Base.decode16(hex_string, case: :mixed) do
      decode_all_tlv(raw_bytes, %{})
    end
  end

  defp decode_all_tlv(<<>>, result), do: {:ok, result}

  defp decode_all_tlv(<<tag::16, len::16, value::binary-size(len), rest::binary>>, result) do
    with {t, v} <- decode_tlv(tag, value) do
      decode_all_tlv(rest, Map.put(result, t, v))
    end
  end

  defp decode_all_tlv(_unexpected, _result), do: :error

  defp decode_tlv(0x100E, value) do
    with {:ok, decoded} <- decode_all_tlv(value, %{}) do
      {:credential, decoded}
    end
  end

  defp decode_tlv(0x1045, value), do: {:ssid, value}
  defp decode_tlv(0x1027, value), do: {:network_key, value}

  defp decode_tlv(0x1020, <<value::binary-size(6)>>) do
    mac =
      value
      |> Base.encode16()
      |> String.codepoints()
      |> Enum.chunk_every(2)
      |> Enum.join(":")

    {:mac_address, mac}
  end

  defp decode_tlv(0x1026, <<n>>), do: {:network_index, n}
  defp decode_tlv(tag, value), do: {tag, value}
end

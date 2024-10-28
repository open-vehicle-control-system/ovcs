defmodule PropertyTable.PersistFile do
  @moduledoc false
  # This module contains methods to aid in writing the contents of a PropertyTable to a custom file format.
  #
  # The structure of the format is the following:
  #
  # +--------+------+------------------------------------------+
  # | OFFSET | SIZE | DESCRIPTION                              |
  # +--------+------+------------------------------------------+
  # |      0 |    6 | Header - set to 'PTABLE'                 |
  # +--------+------+------------------------------------------+
  # |      6 |    1 | File version - set to 1                  |
  # +--------+------+------------------------------------------+
  # |      7 |    1 | Reserved - set to 0                      |
  # +--------+------+------------------------------------------+
  # |      8 |    8 | Size of the table contents as big endian |
  # +--------+------+------------------------------------------+
  # |     16 |    n | Table contents as an encoded Erlang term |
  # +--------+------+------------------------------------------+
  # |   16+n |   16 | MD5 checksum of the table contents       |
  # +--------+------+------------------------------------------+

  # PTABLE header bytes
  @magic_file_header <<80, 84, 65, 66, 76, 69>>

  # Presently this version number is not used for anything, but if we want to change
  # the internal format of how we store the table, we can use this to version the layouts
  @file_version 1

  @spec decode_file(binary()) :: {:error, :bad_checksum | :bad_file} | {:ok, binary()}
  def decode_file(file_path) when is_binary(file_path) do
    file_content = File.read!(file_path)

    case decode_binary(file_content) do
      {:ok, decoded} -> validate_payload(decoded.payload, decoded.hash)
      error -> error
    end
  end

  @spec encode_binary(binary()) :: [binary(), ...]
  def encode_binary(table_content_binary) when is_binary(table_content_binary) do
    payload_length = byte_size(table_content_binary)
    payload_hash = :crypto.hash(:md5, table_content_binary)

    header = <<
      @magic_file_header::binary,
      @file_version::8,
      # Reserved byte
      0x0::8,
      payload_length::64
    >>

    [
      header,
      table_content_binary,
      payload_hash
    ]
  end

  defp validate_payload(payload, hash) do
    check_hash = :crypto.hash(:md5, payload)

    if hash != check_hash do
      {:error, :bad_checksum}
    else
      {:ok, payload}
    end
  end

  defp decode_binary(
         <<@magic_file_header, version::8, _reserved::8, payload_len::64,
           table_content::binary-size(payload_len), payload_hash::binary>>
       ),
       do:
         {:ok,
          %{
            file_version: version,
            payload: table_content,
            hash: payload_hash
          }}

  defp decode_binary(_), do: {:error, :bad_file}
end

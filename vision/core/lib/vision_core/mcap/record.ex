defmodule VisionCore.Mcap.Record do
  @moduledoc """
  Encodes the records of an MCAP file, version 0 of the format
  (https://mcap.dev/spec): each record is its opcode, its content's byte
  length as a uint64 and its content, integers little-endian, strings,
  arrays and maps prefixed by their uint32 byte length.

  Every function returns the whole record as iodata, so message bytes are
  not copied. `VisionCore.Mcap.Writer` places the records in the file.
  """

  @magic <<0x89, "MCAP", 0x30, "\r\n">>

  @opcodes %{
    header: 0x01,
    footer: 0x02,
    schema: 0x03,
    channel: 0x04,
    message: 0x05,
    chunk: 0x06,
    message_index: 0x07,
    chunk_index: 0x08,
    attachment: 0x09,
    attachment_index: 0x0A,
    statistics: 0x0B,
    metadata: 0x0C,
    metadata_index: 0x0D,
    summary_offset: 0x0E,
    data_end: 0x0F
  }

  @compressions %{zstd: "zstd", none: ""}

  @typedoc "A summary record group, named after its records."
  @type summary_group ::
          :schema | :channel | :chunk_index | :attachment_index | :metadata_index | :statistics

  @typedoc "How a chunk's records are compressed."
  @type compression :: :zstd | :none

  @doc "The magic bytes an MCAP file starts and ends with."
  @spec magic() :: binary()
  def magic, do: @magic

  @doc "The Header record."
  @spec header(String.t(), String.t()) :: iodata()
  def header(profile, library), do: record(:header, [prefixed(profile), prefixed(library)])

  @doc """
  The Footer record. Its CRC covers the summary and summary offset sections,
  whose CRC is `summary_crc`, and the footer's own bytes before the CRC.
  """
  @spec footer(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: iodata()
  def footer(summary_start, summary_offset_start, summary_crc) do
    fields =
      IO.iodata_to_binary(record(:footer, 20, [u64(summary_start), u64(summary_offset_start)]))

    [fields, u32(:erlang.crc32(summary_crc, fields))]
  end

  @doc "The Schema record."
  @spec schema(pos_integer(), String.t(), String.t(), iodata()) :: iodata()
  def schema(id, name, encoding, data),
    do: record(:schema, [u16(id), prefixed(name), prefixed(encoding), prefixed(data)])

  @doc "The Channel record."
  @spec channel(non_neg_integer(), non_neg_integer(), String.t(), String.t(), %{
          String.t() => String.t()
        }) :: iodata()
  def channel(id, schema_id, topic, message_encoding, metadata) do
    record(:channel, [
      u16(id),
      u16(schema_id),
      prefixed(topic),
      prefixed(message_encoding),
      string_map(metadata)
    ])
  end

  @doc "The Message record."
  @spec message(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          iodata()
        ) ::
          iodata()
  def message(channel_id, sequence, log_time, publish_time, data),
    do: record(:message, [u16(channel_id), u32(sequence), u64(log_time), u64(publish_time), data])

  @doc """
  The Chunk record over `records`, already compressed per `compression`;
  `uncompressed_size` and `uncompressed_crc` are the records' before
  compression.
  """
  @spec chunk(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          compression(),
          iodata()
        ) :: iodata()
  def chunk(
        message_start_time,
        message_end_time,
        uncompressed_size,
        uncompressed_crc,
        compression,
        records
      ) do
    record(:chunk, [
      u64(message_start_time),
      u64(message_end_time),
      u64(uncompressed_size),
      u32(uncompressed_crc),
      prefixed(Map.fetch!(@compressions, compression)),
      u64(IO.iodata_length(records)),
      records
    ])
  end

  @doc "The Message Index record of a channel: each message's log time and offset in the uncompressed chunk."
  @spec message_index(non_neg_integer(), [{non_neg_integer(), non_neg_integer()}]) :: iodata()
  def message_index(channel_id, entries) do
    entries = for {log_time, offset} <- entries, do: [u64(log_time), u64(offset)]
    record(:message_index, [u16(channel_id), prefixed(entries)])
  end

  @doc "The Chunk Index record."
  @spec chunk_index(%{
          message_start_time: non_neg_integer(),
          message_end_time: non_neg_integer(),
          chunk_start_offset: non_neg_integer(),
          chunk_length: non_neg_integer(),
          message_index_offsets: %{non_neg_integer() => non_neg_integer()},
          message_index_length: non_neg_integer(),
          compression: compression(),
          compressed_size: non_neg_integer(),
          uncompressed_size: non_neg_integer()
        }) :: iodata()
  def chunk_index(chunk_index) do
    record(:chunk_index, [
      u64(chunk_index.message_start_time),
      u64(chunk_index.message_end_time),
      u64(chunk_index.chunk_start_offset),
      u64(chunk_index.chunk_length),
      u16_u64_map(chunk_index.message_index_offsets),
      u64(chunk_index.message_index_length),
      prefixed(Map.fetch!(@compressions, chunk_index.compression)),
      u64(chunk_index.compressed_size),
      u64(chunk_index.uncompressed_size)
    ])
  end

  @doc "The Attachment record, with the CRC of its fields."
  @spec attachment(non_neg_integer(), non_neg_integer(), String.t(), String.t(), iodata()) ::
          iodata()
  def attachment(log_time, create_time, name, media_type, data) do
    fields = [
      u64(log_time),
      u64(create_time),
      prefixed(name),
      prefixed(media_type),
      u64(IO.iodata_length(data)),
      data
    ]

    record(:attachment, [fields, u32(:erlang.crc32(fields))])
  end

  @doc "The Attachment Index record."
  @spec attachment_index(%{
          offset: non_neg_integer(),
          length: non_neg_integer(),
          log_time: non_neg_integer(),
          create_time: non_neg_integer(),
          data_size: non_neg_integer(),
          name: String.t(),
          media_type: String.t()
        }) :: iodata()
  def attachment_index(attachment_index) do
    record(:attachment_index, [
      u64(attachment_index.offset),
      u64(attachment_index.length),
      u64(attachment_index.log_time),
      u64(attachment_index.create_time),
      u64(attachment_index.data_size),
      prefixed(attachment_index.name),
      prefixed(attachment_index.media_type)
    ])
  end

  @doc "The Metadata record."
  @spec metadata(String.t(), %{String.t() => String.t()}) :: iodata()
  def metadata(name, metadata), do: record(:metadata, [prefixed(name), string_map(metadata)])

  @doc "The Metadata Index record."
  @spec metadata_index(non_neg_integer(), non_neg_integer(), String.t()) :: iodata()
  def metadata_index(offset, length, name),
    do: record(:metadata_index, [u64(offset), u64(length), prefixed(name)])

  @doc "The Data End record, with the CRC of every byte of the file before it."
  @spec data_end(non_neg_integer()) :: iodata()
  def data_end(data_section_crc), do: record(:data_end, [u32(data_section_crc)])

  @doc "The Statistics record."
  @spec statistics(%{
          message_count: non_neg_integer(),
          schema_count: non_neg_integer(),
          channel_count: non_neg_integer(),
          attachment_count: non_neg_integer(),
          metadata_count: non_neg_integer(),
          chunk_count: non_neg_integer(),
          message_start_time: non_neg_integer(),
          message_end_time: non_neg_integer(),
          channel_message_counts: %{non_neg_integer() => non_neg_integer()}
        }) :: iodata()
  def statistics(statistics) do
    record(:statistics, [
      u64(statistics.message_count),
      u16(statistics.schema_count),
      u32(statistics.channel_count),
      u32(statistics.attachment_count),
      u32(statistics.metadata_count),
      u32(statistics.chunk_count),
      u64(statistics.message_start_time),
      u64(statistics.message_end_time),
      u16_u64_map(statistics.channel_message_counts)
    ])
  end

  @doc "The Summary Offset record of a group of summary records."
  @spec summary_offset(summary_group(), non_neg_integer(), non_neg_integer()) :: iodata()
  def summary_offset(group, group_start, group_length),
    do:
      record(:summary_offset, [
        <<Map.fetch!(@opcodes, group)>>,
        u64(group_start),
        u64(group_length)
      ])

  defp record(kind, content), do: record(kind, IO.iodata_length(content), content)

  defp record(kind, content_length, content),
    do: [<<Map.fetch!(@opcodes, kind), content_length::little-64>> | content]

  defp u16(integer), do: <<integer::little-16>>
  defp u32(integer), do: <<integer::little-32>>
  defp u64(integer), do: <<integer::little-64>>

  # Strings, Bytes, Arrays and Maps all carry their uint32 byte length first.
  defp prefixed(iodata), do: [u32(IO.iodata_length(iodata)), iodata]

  defp string_map(map) do
    map
    |> Enum.sort()
    |> Enum.map(fn {key, value} -> [prefixed(key), prefixed(value)] end)
    |> prefixed()
  end

  defp u16_u64_map(map) do
    map |> Enum.sort() |> Enum.map(fn {key, value} -> [u16(key), u64(value)] end) |> prefixed()
  end
end

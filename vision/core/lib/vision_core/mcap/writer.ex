defmodule VisionCore.Mcap.Writer do
  @moduledoc """
  Writes an MCAP file (https://mcap.dev/spec): messages in chunks, each
  compressed with OTP's `:zstd` or left uncompressed and followed by its
  message indexes, then at `close/1` the summary that indexes the file.

  A plain data structure over a raw file, which only the process that
  opened it may use. Schemas, channels, attachments and metadata go to the
  file when they are added; messages wait in the open chunk until
  `close_chunk/1` writes it. A file cut short reads up to its last whole
  chunk.

  A write the file refuses raises `File.Error`, except in `close/1`, which
  closes the file and answers the error.
  """

  alias VisionCore.Mcap.Record

  @options [profile: "ros2", library: "ovcs vision", compression: :zstd, zstd_level: 1]
  @delayed_write_bytes 1_048_576
  @delayed_write_ms 1_000

  @enforce_keys [:path, :file, :compression, :zstd_level]
  defstruct [
    :path,
    :file,
    :compression,
    :zstd_level,
    position: 0,
    data_crc: 0,
    schemas: [],
    channels: [],
    chunk: nil,
    chunk_indexes: [],
    attachment_indexes: [],
    metadata_indexes: [],
    channel_message_counts: %{},
    message_start_time: nil,
    message_end_time: nil
  ]

  @opaque t :: %__MODULE__{}

  @type metadata :: %{String.t() => String.t()}

  @doc """
  Creates the file at `path`, replacing any, and writes its magic and Header.

  Options:
    * `:profile` - the Header's profile (`"ros2"`)
    * `:library` - the Header's library (`"ovcs vision"`)
    * `:compression` - `:zstd` or `:none`, for every chunk (`:zstd`)
    * `:zstd_level` - the zstd compression level (`1`)
  """
  @spec open(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(path, opts) do
    opts = Keyword.validate!(opts, @options)

    with {:ok, file} <-
           :file.open(path, [
             :raw,
             :binary,
             :write,
             {:delayed_write, @delayed_write_bytes, @delayed_write_ms}
           ]) do
      writer = %__MODULE__{
        path: path,
        file: file,
        compression: Keyword.fetch!(opts, :compression),
        zstd_level: Keyword.fetch!(opts, :zstd_level),
        chunk: empty_chunk()
      }

      {:ok, write!(writer, [Record.magic(), Record.header(opts[:profile], opts[:library])])}
    end
  end

  @doc "Writes a Schema record and answers its id, from 1 up."
  @spec add_schema(t(), String.t(), String.t(), iodata()) :: {t(), pos_integer()}
  def add_schema(%__MODULE__{} = writer, name, encoding, data) do
    id = length(writer.schemas) + 1
    record = Record.schema(id, name, encoding, data)
    {%{write!(writer, record) | schemas: [record | writer.schemas]}, id}
  end

  @doc "Writes a Channel record and answers its id, from 1 up."
  @spec add_channel(t(), pos_integer(), String.t(), String.t(), metadata()) ::
          {t(), pos_integer()}
  def add_channel(%__MODULE__{} = writer, schema_id, topic, message_encoding, metadata) do
    id = length(writer.channels) + 1
    record = Record.channel(id, schema_id, topic, message_encoding, metadata)

    writer = %{
      write!(writer, record)
      | channels: [record | writer.channels],
        channel_message_counts: Map.put(writer.channel_message_counts, id, 0)
    }

    {writer, id}
  end

  @doc "Adds a message on a channel added before to the open chunk."
  @spec write_message(
          t(),
          pos_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          iodata()
        ) :: t()
  def write_message(%__MODULE__{} = writer, channel_id, sequence, log_time, publish_time, data) do
    record = Record.message(channel_id, sequence, log_time, publish_time, data)
    chunk = writer.chunk
    index_entry = {log_time, chunk.size}

    chunk = %{
      chunk
      | records: [record | chunk.records],
        size: chunk.size + IO.iodata_length(record),
        start_time: min(chunk.start_time || log_time, log_time),
        end_time: max(chunk.end_time || log_time, log_time),
        message_indexes:
          Map.update(chunk.message_indexes, channel_id, [index_entry], &[index_entry | &1])
    }

    %{
      writer
      | chunk: chunk,
        channel_message_counts: Map.update!(writer.channel_message_counts, channel_id, &(&1 + 1))
    }
  end

  @doc """
  Writes the open chunk, compressed per the `:compression` option, and its
  message indexes, then opens an empty one. Does nothing when the open
  chunk holds no message.
  """
  @spec close_chunk(t()) :: t()
  def close_chunk(%__MODULE__{} = writer) do
    {chunk_bytes, writer} = take_chunk(writer)
    write_file!(writer, chunk_bytes)
  end

  @doc """
  Puts what was written to the file, held back writes included, on the
  disk (`:file.datasync/1`). The open chunk waits for `close_chunk/1`.
  """
  @spec sync(t()) :: t()
  def sync(%__MODULE__{} = writer) do
    case :file.datasync(writer.file) do
      :ok -> writer
      {:error, reason} -> raise File.Error, reason: reason, action: "sync", path: writer.path
    end
  end

  @doc "Writes an Attachment record."
  @spec add_attachment(
          t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          iodata()
        ) ::
          t()
  def add_attachment(%__MODULE__{} = writer, name, media_type, log_time, create_time, data) do
    record = Record.attachment(log_time, create_time, name, media_type, data)

    attachment_index =
      Record.attachment_index(%{
        offset: writer.position,
        length: IO.iodata_length(record),
        log_time: log_time,
        create_time: create_time,
        data_size: IO.iodata_length(data),
        name: name,
        media_type: media_type
      })

    %{write!(writer, record) | attachment_indexes: [attachment_index | writer.attachment_indexes]}
  end

  @doc "Writes a Metadata record."
  @spec add_metadata(t(), String.t(), metadata()) :: t()
  def add_metadata(%__MODULE__{} = writer, name, metadata) do
    record = Record.metadata(name, metadata)
    metadata_index = Record.metadata_index(writer.position, IO.iodata_length(record), name)
    %{write!(writer, record) | metadata_indexes: [metadata_index | writer.metadata_indexes]}
  end

  @doc "The bytes written to the file so far; the open chunk's wait for `close_chunk/1`."
  @spec bytes_written(t()) :: non_neg_integer()
  def bytes_written(%__MODULE__{position: position}), do: position

  @doc """
  Writes the open chunk, Data End, the summary, the summary offsets, Footer
  and magic, and closes the file. Answers the error of any write the file
  refused, this one's or one held back before.
  """
  @spec close(t()) :: :ok | {:error, term()}
  def close(%__MODULE__{} = writer) do
    {chunk_bytes, writer} = take_chunk(writer)
    data_end = Record.data_end(writer.data_crc)
    summary_start = writer.position + IO.iodata_length(data_end)
    {summary, summary_offsets} = summary(writer, summary_start)
    summary_offset_start = summary_start + IO.iodata_length(summary)
    summary_crc = :erlang.crc32([summary, summary_offsets])
    footer = Record.footer(summary_start, summary_offset_start, summary_crc)

    written =
      :file.write(writer.file, [
        chunk_bytes,
        data_end,
        summary,
        summary_offsets,
        footer,
        Record.magic()
      ])

    closed = :file.close(writer.file)
    if written == :ok, do: closed, else: written
  end

  # The open chunk's records and message indexes, counted as written.
  defp take_chunk(%__MODULE__{chunk: %{records: []}} = writer), do: {[], writer}

  defp take_chunk(%__MODULE__{chunk: chunk} = writer) do
    records = Enum.reverse(chunk.records)
    compressed = compress(records, writer.compression, writer.zstd_level)

    chunk_record =
      Record.chunk(
        chunk.start_time,
        chunk.end_time,
        chunk.size,
        :erlang.crc32(records),
        writer.compression,
        compressed
      )

    chunk_length = IO.iodata_length(chunk_record)

    {message_indexes, message_index_offsets} =
      message_indexes(chunk, writer.position + chunk_length)

    chunk_index =
      Record.chunk_index(%{
        message_start_time: chunk.start_time,
        message_end_time: chunk.end_time,
        chunk_start_offset: writer.position,
        chunk_length: chunk_length,
        message_index_offsets: message_index_offsets,
        message_index_length: IO.iodata_length(message_indexes),
        compression: writer.compression,
        compressed_size: IO.iodata_length(compressed),
        uncompressed_size: chunk.size
      })

    chunk_bytes = [chunk_record, message_indexes]

    {chunk_bytes,
     %{
       count_written(writer, chunk_bytes)
       | chunk: empty_chunk(),
         chunk_indexes: [chunk_index | writer.chunk_indexes],
         message_start_time: min(writer.message_start_time || chunk.start_time, chunk.start_time),
         message_end_time: max(writer.message_end_time || chunk.end_time, chunk.end_time)
     }}
  end

  defp empty_chunk,
    do: %{records: [], size: 0, start_time: nil, end_time: nil, message_indexes: %{}}

  defp compress(records, :none, _level), do: records
  defp compress(records, :zstd, level), do: :zstd.compress(records, %{compressionLevel: level})

  defp message_indexes(chunk, offset) do
    {records, {offsets, _end}} =
      chunk.message_indexes
      |> Enum.sort()
      |> Enum.map_reduce({%{}, offset}, fn {channel_id, entries}, {offsets, offset} ->
        record = Record.message_index(channel_id, Enum.reverse(entries))
        {record, {Map.put(offsets, channel_id, offset), offset + IO.iodata_length(record)}}
      end)

    {records, offsets}
  end

  defp summary(writer, summary_start) do
    groups =
      [
        schema: Enum.reverse(writer.schemas),
        channel: Enum.reverse(writer.channels),
        chunk_index: Enum.reverse(writer.chunk_indexes),
        attachment_index: Enum.reverse(writer.attachment_indexes),
        metadata_index: Enum.reverse(writer.metadata_indexes),
        statistics: [Record.statistics(statistics(writer))]
      ]
      |> Enum.reject(fn {_group, records} -> records == [] end)

    {offsets, _end} =
      Enum.map_reduce(groups, summary_start, fn {group, records}, group_start ->
        group_length = IO.iodata_length(records)
        {Record.summary_offset(group, group_start, group_length), group_start + group_length}
      end)

    {Enum.map(groups, &elem(&1, 1)), offsets}
  end

  defp statistics(writer) do
    %{
      message_count: writer.channel_message_counts |> Map.values() |> Enum.sum(),
      schema_count: length(writer.schemas),
      channel_count: length(writer.channels),
      attachment_count: length(writer.attachment_indexes),
      metadata_count: length(writer.metadata_indexes),
      chunk_count: length(writer.chunk_indexes),
      message_start_time: writer.message_start_time || 0,
      message_end_time: writer.message_end_time || 0,
      channel_message_counts: writer.channel_message_counts
    }
  end

  defp write!(writer, iodata), do: writer |> write_file!(iodata) |> count_written(iodata)

  defp write_file!(writer, iodata) do
    case :file.write(writer.file, iodata) do
      :ok -> writer
      {:error, reason} -> raise File.Error, reason: reason, action: "write to", path: writer.path
    end
  end

  defp count_written(writer, iodata) do
    %{
      writer
      | position: writer.position + IO.iodata_length(iodata),
        data_crc: :erlang.crc32(writer.data_crc, iodata)
    }
  end
end

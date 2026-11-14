defmodule VisionCore.McapReader do
  @moduledoc """
  An MCAP reader for the tests (https://mcap.dev/spec), independent of
  `VisionCore.Mcap.Record`: it raises on any record out of place, any CRC
  that is zero or does not check, and any index that does not point at what
  it describes.

  `read!/1` reads a whole file twice: linearly through its data section,
  and through its summary (chunk indexes, then message indexes, then the
  messages in the chunks). `read_complete_chunks!/1` reads a file cut short
  up to its last whole record.
  """

  @magic <<0x89, "MCAP0\r\n">>

  @header 0x01
  @footer 0x02
  @schema 0x03
  @channel 0x04
  @message 0x05
  @chunk 0x06
  @message_index 0x07
  @chunk_index 0x08
  @attachment 0x09
  @attachment_index 0x0A
  @statistics 0x0B
  @metadata 0x0C
  @metadata_index 0x0D
  @summary_offset 0x0E
  @data_end 0x0F

  @summary_opcodes [
    @schema,
    @channel,
    @chunk_index,
    @attachment_index,
    @metadata_index,
    @statistics
  ]

  @doc """
  Reads a whole MCAP file: its header, the records of its data section in
  order (`:records`, each `{opcode, offset, length}`), its schemas,
  channels (and the offset of the record or chunk that first defines each,
  `:channel_offsets`), messages, chunks, attachments and metadata, its summary, and the
  messages as its indexes find them (`:indexed_messages`).
  """
  @spec read!(binary()) :: map()
  def read!(file) do
    {:data_end, data} = read_data_section(file)
    footer = read_footer!(file)
    summary = read_summary!(file, footer)

    check_summary!(data, summary)

    data
    |> Map.put(:summary, summary)
    |> Map.put(:indexed_messages, indexed_messages!(file, summary))
  end

  @doc """
  Reads the data section of a file cut short, up to its last whole record,
  and returns the messages of its whole chunks.
  """
  @spec read_complete_chunks!(binary()) :: [map()]
  def read_complete_chunks!(file) do
    {_end, data} = read_data_section(file)
    data.messages
  end

  defp read_data_section(<<@magic, _rest::binary>> = file) do
    {@header, header, after_header} = record!(file, byte_size(@magic))

    state = %{
      header: read_header(header),
      records: [],
      schemas: %{},
      channels: %{},
      channel_offsets: %{},
      messages: [],
      chunks: [],
      attachments: [],
      metadata: []
    }

    {ending, state} = read_records(file, after_header, state)
    {ending, finish(state, ending)}
  end

  defp read_records(file, offset, state) do
    case next_record(file, offset) do
      :incomplete ->
        {:cut, state}

      {@data_end, <<crc::little-32>>, _next} ->
        check_crc!(crc, binary_part(file, 0, offset), :data_end)
        {:data_end, state}

      {opcode, content, next} ->
        state = %{state | records: [{opcode, offset, next - offset} | state.records]}
        read_records(file, next, read_data_record(opcode, content, {offset, next}, state))
    end
  end

  defp read_data_record(@schema, content, _span, state), do: add_schema!(state, content)

  defp read_data_record(@channel, content, {offset, _next}, state),
    do: add_channel!(state, content, offset)

  defp read_data_record(@chunk, content, {offset, next}, state) do
    chunk = read_chunk!(content)
    state = read_chunk_records(chunk.records, 0, offset, state)
    chunk = %{Map.delete(chunk, :records) | offset: offset, length: next - offset}
    %{state | chunks: [chunk | state.chunks]}
  end

  defp read_data_record(@message_index, content, {offset, next}, state) do
    [chunk | chunks] = state.chunks
    ^offset = chunk.offset + chunk.length + chunk.message_index_length
    {channel_id, entries} = read_message_index(content)
    false = Map.has_key?(chunk.message_indexes, channel_id)

    chunk = %{
      chunk
      | message_indexes: Map.put(chunk.message_indexes, channel_id, entries),
        message_index_offsets: Map.put(chunk.message_index_offsets, channel_id, offset),
        message_index_length: chunk.message_index_length + next - offset
    }

    %{state | chunks: [chunk | chunks]}
  end

  defp read_data_record(@attachment, content, {offset, next}, state) do
    attachment = read_attachment!(content) |> Map.merge(%{offset: offset, length: next - offset})
    %{state | attachments: [attachment | state.attachments]}
  end

  defp read_data_record(@metadata, content, {offset, next}, state) do
    {name, rest} = string(content)
    {metadata, <<>>} = string_map(rest)
    entry = %{name: name, metadata: metadata, offset: offset, length: next - offset}
    %{state | metadata: [entry | state.metadata]}
  end

  defp read_chunk_records(<<>>, _offset, _chunk_offset, state), do: state

  defp read_chunk_records(records, offset, chunk_offset, state) do
    {opcode, content, next} = record!(records, offset)

    state =
      case opcode do
        @schema ->
          add_schema!(state, content)

        @channel ->
          add_channel!(state, content, chunk_offset)

        @message ->
          message = read_message!(content, state)
          message = Map.merge(message, %{chunk_offset: chunk_offset, offset: offset})
          %{state | messages: [message | state.messages]}
      end

    if next == byte_size(records),
      do: state,
      else: read_chunk_records(records, next, chunk_offset, state)
  end

  defp finish(state, ending) do
    chunks = Enum.reverse(state.chunks)
    messages = Enum.reverse(state.messages)
    Enum.each(chunks, &check_message_indexes!(&1, messages, ending))

    %{
      state
      | records: Enum.reverse(state.records),
        messages: Enum.map(messages, &Map.drop(&1, [:offset])),
        chunks: chunks,
        attachments: Enum.reverse(state.attachments),
        metadata: Enum.reverse(state.metadata)
    }
  end

  # A file cut short may lose the message indexes of its last whole chunk, not its messages.
  defp check_message_indexes!(chunk, messages, ending) do
    chunk_messages = Enum.filter(messages, &(&1.chunk_offset == chunk.offset))

    if ending == :data_end do
      channels = chunk_messages |> Enum.map(& &1.channel_id) |> Enum.uniq() |> Enum.sort()
      ^channels = chunk.message_indexes |> Map.keys() |> Enum.sort()
    end

    for {channel_id, entries} <- chunk.message_indexes do
      indexed = Enum.map(entries, fn {_log_time, offset} -> offset end) |> Enum.sort()
      on_channel = for m <- chunk_messages, m.channel_id == channel_id, do: m
      ^indexed = Enum.map(on_channel, & &1.offset)

      for {log_time, offset} <- entries,
          do: %{log_time: ^log_time} = Enum.find(on_channel, &(&1.offset == offset))
    end
  end

  defp read_header(content) do
    {profile, rest} = string(content)
    {library, <<>>} = string(rest)
    %{profile: profile, library: library}
  end

  defp add_schema!(state, content) do
    {id, schema} = read_schema(content)
    true = id > 0
    check_redefinition!(state.schemas, id, schema)
    %{state | schemas: Map.put(state.schemas, id, schema)}
  end

  defp add_channel!(state, content, offset) do
    {id, channel} = read_channel(content)
    true = channel.schema_id == 0 or Map.has_key?(state.schemas, channel.schema_id)
    check_redefinition!(state.channels, id, channel)

    %{
      state
      | channels: Map.put(state.channels, id, channel),
        channel_offsets: Map.put_new(state.channel_offsets, id, offset)
    }
  end

  defp check_redefinition!(known, id, definition) do
    case known do
      %{^id => ^definition} -> :ok
      %{^id => _other} -> raise "id #{id} defined twice differently"
      %{} -> :ok
    end
  end

  defp read_schema(<<id::little-16, rest::binary>>) do
    {name, rest} = string(rest)
    {encoding, rest} = string(rest)
    {data, <<>>} = string(rest)
    {id, %{name: name, encoding: encoding, data: data}}
  end

  defp read_channel(<<id::little-16, schema_id::little-16, rest::binary>>) do
    {topic, rest} = string(rest)
    {message_encoding, rest} = string(rest)
    {metadata, <<>>} = string_map(rest)

    {id,
     %{schema_id: schema_id, topic: topic, message_encoding: message_encoding, metadata: metadata}}
  end

  defp read_message!(content, state) do
    <<channel_id::little-16, sequence::little-32, log_time::little-64, publish_time::little-64,
      data::binary>> = content

    unless Map.has_key?(state.channels, channel_id),
      do: raise("message on channel #{channel_id} before its channel")

    %{
      channel_id: channel_id,
      sequence: sequence,
      log_time: log_time,
      publish_time: publish_time,
      data: data
    }
  end

  defp read_chunk!(content) do
    <<start_time::little-64, end_time::little-64, uncompressed_size::little-64,
      uncompressed_crc::little-32, rest::binary>> = content

    {compression, rest} = string(rest)
    <<compressed_size::little-64, compressed::binary-size(compressed_size)>> = rest
    records = decompress!(compression, compressed)
    ^uncompressed_size = byte_size(records)
    check_crc!(uncompressed_crc, records, :chunk)

    %{
      message_start_time: start_time,
      message_end_time: end_time,
      uncompressed_size: uncompressed_size,
      compression: compression,
      compressed_size: compressed_size,
      records: records,
      offset: nil,
      length: nil,
      message_indexes: %{},
      message_index_offsets: %{},
      message_index_length: 0
    }
  end

  defp decompress!("", records), do: records

  defp decompress!("zstd", compressed),
    do: compressed |> :zstd.decompress() |> IO.iodata_to_binary()

  defp read_message_index(<<channel_id::little-16, length::little-32, entries::binary>>) do
    ^length = byte_size(entries)

    {channel_id,
     for(<<log_time::little-64, offset::little-64 <- entries>>, do: {log_time, offset})}
  end

  defp read_attachment!(content) do
    fields_size = byte_size(content) - 4
    <<fields::binary-size(^fields_size), crc::little-32>> = content
    check_crc!(crc, fields, :attachment)

    <<log_time::little-64, create_time::little-64, rest::binary>> = fields
    {name, rest} = string(rest)
    {media_type, rest} = string(rest)
    <<data_size::little-64, data::binary-size(data_size)>> = rest

    %{
      log_time: log_time,
      create_time: create_time,
      name: name,
      media_type: media_type,
      data: data
    }
  end

  defp read_footer!(file) do
    footer_offset = byte_size(file) - byte_size(@magic) - 29
    <<_data::binary-size(^footer_offset), footer::binary-size(29), @magic>> = file

    <<@footer, 20::little-64, summary_start::little-64, summary_offset_start::little-64,
      summary_crc::little-32>> = footer

    true = summary_start > 0 and summary_offset_start > summary_start
    summary_size = footer_offset + 25 - summary_start
    check_crc!(summary_crc, binary_part(file, summary_start, summary_size), :footer)

    %{
      offset: footer_offset,
      summary_start: summary_start,
      summary_offset_start: summary_offset_start
    }
  end

  defp read_summary!(file, footer) do
    summary = records_between(file, footer.summary_start, footer.summary_offset_start)
    offsets = records_between(file, footer.summary_offset_start, footer.offset)
    check_summary_offsets!(summary, offsets)

    %{
      schemas: for({@schema, _offset, content} <- summary, into: %{}, do: read_schema(content)),
      channels:
        for({@channel, _offset, content} <- summary, into: %{}, do: read_channel(content)),
      chunk_indexes:
        for({@chunk_index, _offset, content} <- summary, do: read_chunk_index(content)),
      attachment_indexes:
        for({@attachment_index, _offset, content} <- summary, do: read_attachment_index(content)),
      metadata_indexes:
        for({@metadata_index, _offset, content} <- summary, do: read_metadata_index(content)),
      statistics:
        single!(for {@statistics, _offset, content} <- summary, do: read_statistics(content))
    }
  end

  defp records_between(_file, offset, offset), do: []

  defp records_between(file, offset, end_offset) do
    {opcode, content, next} = record!(file, offset)
    true = next <= end_offset
    [{opcode, offset, content} | records_between(file, next, end_offset)]
  end

  # Summary records grouped by opcode, each group with its Summary Offset, in the order written.
  defp check_summary_offsets!(summary, offsets) do
    groups =
      summary
      |> Enum.chunk_by(fn {opcode, _offset, _content} -> opcode end)
      |> Enum.map(fn [{opcode, start, _content} | _rest] = group ->
        {last_opcode, last_offset, last_content} = List.last(group)
        ^last_opcode = opcode
        {opcode, start, last_offset + 9 + byte_size(last_content) - start}
      end)

    group_opcodes = Enum.map(groups, &elem(&1, 0))
    ^group_opcodes = Enum.uniq(group_opcodes)
    true = Enum.all?(group_opcodes, &(&1 in @summary_opcodes))

    ^groups =
      for {@summary_offset, _offset, content} <- offsets do
        <<opcode, start::little-64, length::little-64>> = content
        {opcode, start, length}
      end
  end

  defp read_chunk_index(content) do
    <<start_time::little-64, end_time::little-64, chunk_start_offset::little-64,
      chunk_length::little-64, rest::binary>> = content

    {message_index_offsets, rest} = u16_u64_map(rest)
    <<message_index_length::little-64, rest::binary>> = rest
    {compression, rest} = string(rest)
    <<compressed_size::little-64, uncompressed_size::little-64>> = rest

    %{
      message_start_time: start_time,
      message_end_time: end_time,
      offset: chunk_start_offset,
      length: chunk_length,
      message_index_offsets: message_index_offsets,
      message_index_length: message_index_length,
      compression: compression,
      compressed_size: compressed_size,
      uncompressed_size: uncompressed_size
    }
  end

  defp read_attachment_index(content) do
    <<offset::little-64, length::little-64, log_time::little-64, create_time::little-64,
      data_size::little-64, rest::binary>> = content

    {name, rest} = string(rest)
    {media_type, <<>>} = string(rest)

    %{
      offset: offset,
      length: length,
      log_time: log_time,
      create_time: create_time,
      data_size: data_size,
      name: name,
      media_type: media_type
    }
  end

  defp read_metadata_index(<<offset::little-64, length::little-64, rest::binary>>) do
    {name, <<>>} = string(rest)
    %{offset: offset, length: length, name: name}
  end

  defp read_statistics(content) do
    <<message_count::little-64, schema_count::little-16, channel_count::little-32,
      attachment_count::little-32, metadata_count::little-32, chunk_count::little-32,
      start_time::little-64, end_time::little-64, rest::binary>> = content

    {channel_message_counts, <<>>} = u16_u64_map(rest)

    %{
      message_count: message_count,
      schema_count: schema_count,
      channel_count: channel_count,
      attachment_count: attachment_count,
      metadata_count: metadata_count,
      chunk_count: chunk_count,
      message_start_time: start_time,
      message_end_time: end_time,
      channel_message_counts: channel_message_counts
    }
  end

  defp check_summary!(data, summary) do
    same!(:schemas, data.schemas, summary.schemas)
    same!(:channels, data.channels, summary.channels)
    same!(:chunk_indexes, Enum.map(data.chunks, &chunk_index/1), summary.chunk_indexes)

    same!(
      :attachment_indexes,
      Enum.map(data.attachments, &attachment_index/1),
      summary.attachment_indexes
    )

    same!(
      :metadata_indexes,
      Enum.map(data.metadata, &Map.take(&1, [:offset, :length, :name])),
      summary.metadata_indexes
    )

    same!(:statistics, statistics(data), summary.statistics)
  end

  defp chunk_index(chunk) do
    Map.take(chunk, [
      :message_start_time,
      :message_end_time,
      :offset,
      :length,
      :message_index_offsets,
      :message_index_length,
      :compression,
      :compressed_size,
      :uncompressed_size
    ])
  end

  defp attachment_index(attachment) do
    attachment
    |> Map.take([:offset, :length, :log_time, :create_time, :name, :media_type])
    |> Map.put(:data_size, byte_size(attachment.data))
  end

  defp statistics(data) do
    log_times = Enum.map(data.messages, & &1.log_time)
    no_messages = Map.new(data.channels, fn {id, _channel} -> {id, 0} end)

    %{
      message_count: length(data.messages),
      schema_count: map_size(data.schemas),
      channel_count: map_size(data.channels),
      attachment_count: length(data.attachments),
      metadata_count: length(data.metadata),
      chunk_count: length(data.chunks),
      message_start_time: Enum.min(log_times, fn -> 0 end),
      message_end_time: Enum.max(log_times, fn -> 0 end),
      channel_message_counts:
        Map.merge(no_messages, Enum.frequencies_by(data.messages, & &1.channel_id))
    }
  end

  defp same!(_what, expected, expected), do: :ok

  defp same!(what, expected, summary),
    do:
      raise(
        "summary #{what} #{inspect(summary)} differ from the data section's #{inspect(expected)}"
      )

  defp single!([statistics]), do: statistics

  defp indexed_messages!(file, summary) do
    Enum.flat_map(summary.chunk_indexes, fn chunk_index ->
      {@chunk, content, chunk_end} = record!(file, chunk_index.offset)
      ^chunk_end = chunk_index.offset + chunk_index.length
      records = read_chunk!(content).records

      message_indexes =
        Enum.map(chunk_index.message_index_offsets, fn {channel_id, offset} ->
          {@message_index, content, next} = record!(file, offset)
          {^channel_id, entries} = read_message_index(content)
          {offset, next, entries}
        end)

      ^chunk_end = message_indexes |> Enum.map(&elem(&1, 0)) |> Enum.min()
      message_index_end = chunk_end + chunk_index.message_index_length
      ^message_index_end = message_indexes |> Enum.map(&elem(&1, 1)) |> Enum.max()

      message_indexes
      |> Enum.flat_map(fn {_offset, _next, entries} -> entries end)
      |> Enum.sort_by(fn {_log_time, offset} -> offset end)
      |> Enum.map(fn {log_time, offset} ->
        {@message, content, _next} = record!(records, offset)
        message = read_message!(content, summary)
        ^log_time = message.log_time
        Map.put(message, :chunk_offset, chunk_index.offset)
      end)
    end)
  end

  defp record!(binary, offset) do
    {_opcode, _content, _next} = next_record(binary, offset)
  end

  defp next_record(binary, offset) do
    case binary do
      <<_before::binary-size(^offset), opcode, length::little-64, content::binary-size(length),
        _rest::binary>> ->
        {opcode, content, offset + 9 + length}

      _cut ->
        :incomplete
    end
  end

  defp check_crc!(0, _bytes, what), do: raise("#{what} CRC is zero")

  defp check_crc!(crc, bytes, what) do
    unless :erlang.crc32(bytes) == crc, do: raise("#{what} CRC does not check")
  end

  defp string(<<length::little-32, string::binary-size(length), rest::binary>>),
    do: {string, rest}

  defp string_map(<<length::little-32, entries::binary-size(length), rest::binary>>),
    do: {string_pairs(entries, %{}), rest}

  defp string_pairs(<<>>, map), do: map

  defp string_pairs(entries, map) do
    {key, rest} = string(entries)
    {value, rest} = string(rest)
    false = Map.has_key?(map, key)
    string_pairs(rest, Map.put(map, key, value))
  end

  defp u16_u64_map(<<length::little-32, entries::binary-size(length), rest::binary>>) do
    pairs = for <<key::little-16, value::little-64 <- entries>>, do: {key, value}
    keys = Enum.map(pairs, &elem(&1, 0))
    ^keys = Enum.uniq(keys)
    {Map.new(pairs), rest}
  end
end

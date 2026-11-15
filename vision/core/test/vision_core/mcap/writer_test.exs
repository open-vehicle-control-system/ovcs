defmodule VisionCore.Mcap.WriterTest do
  use ExUnit.Case, async: true

  alias VisionCore.McapReader
  alias VisionCore.Mcap.Writer

  @moduletag :tmp_dir

  @definition "float64 data\n"
  @qos %{"offered_qos_profiles" => ""}

  defp open!(dir, compression) do
    path = Path.join(dir, "#{compression}.mcap")

    {:ok, writer} =
      Writer.open(path,
        profile: "ros2",
        library: "ovcs vision",
        compression: compression,
        zstd_level: 1
      )

    {writer, path}
  end

  defp close!(writer, path) do
    :ok = Writer.close(writer)
    File.read!(path)
  end

  # One schema, two channels, five messages over three chunks.
  defp three_chunks(writer) do
    {writer, schema_id} =
      Writer.add_schema(writer, "std_msgs/msg/Float64", "ros2msg", @definition)

    {writer, speed} = Writer.add_channel(writer, schema_id, "/speed", "cdr", @qos)
    {writer, steering} = Writer.add_channel(writer, schema_id, "/steering", "cdr", @qos)

    messages = [
      [{speed, 0, 1_000, 900, "speed 0"}, {steering, 0, 1_100, 1_050, ["steer", "ing 0"]}],
      [{speed, 1, 2_000, 1_900, "speed 1"}],
      [{steering, 1, 3_100, 3_050, "steering 1"}, {speed, 2, 3_000, 2_900, "speed 2"}]
    ]

    writer =
      Enum.reduce(messages, writer, fn chunk, writer ->
        chunk
        |> Enum.reduce(writer, fn {channel_id, sequence, log_time, publish_time, data}, writer ->
          Writer.write_message(writer, channel_id, sequence, log_time, publish_time, data)
        end)
        |> Writer.close_chunk()
      end)

    expected =
      for {channel_id, sequence, log_time, publish_time, data} <- List.flatten(messages) do
        %{
          channel_id: channel_id,
          sequence: sequence,
          log_time: log_time,
          publish_time: publish_time,
          data: IO.iodata_to_binary(data)
        }
      end

    {writer, %{speed: speed, steering: steering, messages: expected}}
  end

  defp without_chunk(messages), do: Enum.map(messages, &Map.delete(&1, :chunk_offset))

  describe "a file of three chunks" do
    setup %{tmp_dir: dir} do
      {writer, path} = open!(dir, :zstd)
      {writer, written} = three_chunks(writer)
      {:ok, Map.put(written, :mcap, McapReader.read!(close!(writer, path)))}
    end

    test "has the ROS 2 profile and the library in its header", %{mcap: file} do
      assert file.header == %{profile: "ros2", library: "ovcs vision"}
    end

    test "reads back every message in order with its channel, sequence, times and bytes",
         %{mcap: file, messages: messages} do
      assert without_chunk(file.messages) == messages
    end

    test "holds the schema and the channels", %{mcap: file, speed: speed, steering: steering} do
      assert %{1 => %{name: "std_msgs/msg/Float64", encoding: "ros2msg", data: @definition}} ==
               file.schemas

      assert %{
               ^speed => %{schema_id: 1, topic: "/speed", message_encoding: "cdr", metadata: @qos},
               ^steering => %{schema_id: 1, topic: "/steering", message_encoding: "cdr"}
             } = file.channels
    end

    test "writes each chunk with zstd and the message indexes that locate its messages",
         %{mcap: file} do
      assert [%{compression: "zstd"}, %{compression: "zstd"}, %{compression: "zstd"}] =
               file.chunks

      assert Enum.map(file.chunks, &map_size(&1.message_indexes)) == [2, 1, 2]
    end

    test "dates each chunk by its earliest and latest log time", %{mcap: file} do
      assert Enum.map(file.chunks, &{&1.message_start_time, &1.message_end_time}) ==
               [{1_000, 1_100}, {2_000, 2_000}, {3_000, 3_100}]
    end

    test "finds the same messages through its chunk and message indexes", %{mcap: file} do
      assert length(file.summary.chunk_indexes) == 3
      assert file.indexed_messages == file.messages
    end

    test "counts the messages per channel in its statistics",
         %{mcap: file, speed: speed, steering: steering} do
      assert %{
               message_count: 5,
               schema_count: 1,
               channel_count: 2,
               chunk_count: 3,
               attachment_count: 0,
               metadata_count: 0,
               message_start_time: 1_000,
               message_end_time: 3_100,
               channel_message_counts: %{^speed => 3, ^steering => 2}
             } = file.summary.statistics
    end
  end

  test "an uncompressed file reads back the same messages", %{tmp_dir: dir} do
    {writer, path} = open!(dir, :none)
    {writer, %{messages: messages}} = three_chunks(writer)

    file = McapReader.read!(close!(writer, path))

    assert Enum.all?(file.chunks, &(&1.compression == ""))
    assert without_chunk(file.messages) == messages
    assert file.indexed_messages == file.messages
  end

  test "zstd chunks are smaller than uncompressed ones for repetitive data", %{tmp_dir: dir} do
    frame = :binary.copy(<<1, 2, 3, 4>>, 10_000)

    sizes =
      for compression <- [:zstd, :none] do
        {writer, path} = open!(dir, compression)
        {writer, schema_id} = Writer.add_schema(writer, "sensor_msgs/msg/Image", "ros2msg", "")
        {writer, channel_id} = Writer.add_channel(writer, schema_id, "/image", "cdr", @qos)

        writer
        |> Writer.write_message(channel_id, 0, 1_000, 1_000, frame)
        |> Writer.close_chunk()
        |> close!(path)
        |> McapReader.read!()
        |> then(fn %{chunks: [chunk]} -> chunk.compressed_size end)
      end

    assert [zstd, none] = sizes
    assert none > 40_000
    assert zstd < div(none, 10)
  end

  test "a CRC that does not check fails the read", %{tmp_dir: dir} do
    {writer, path} = open!(dir, :none)
    {writer, _written} = three_chunks(writer)
    bytes = close!(writer, path)

    [{offset, _length}] = :binary.matches(bytes, "speed 1")
    <<before::binary-size(^offset), _byte, rest::binary>> = bytes

    assert_raise RuntimeError, ~r/CRC does not check/, fn ->
      McapReader.read!(before <> "S" <> rest)
    end
  end

  test "a file cut at any byte after its second chunk reads back the messages of its whole chunks",
       %{tmp_dir: dir} do
    {writer, path} = open!(dir, :zstd)
    {writer, %{messages: messages}} = three_chunks(writer)
    bytes = close!(writer, path)

    %{chunks: chunks} = McapReader.read!(bytes)
    chunk_ends = Enum.map(chunks, &(&1.offset + &1.length))
    [_first, second_end, _third] = chunk_ends
    messages_per_chunk = [2, 1, 2]

    for cut <- second_end..(byte_size(bytes) - 1) do
      whole_chunks = Enum.count(chunk_ends, &(&1 <= cut))
      expected = Enum.take(messages, messages_per_chunk |> Enum.take(whole_chunks) |> Enum.sum())

      assert without_chunk(McapReader.read_complete_chunks!(binary_part(bytes, 0, cut))) ==
               expected,
             "cut at #{cut}"
    end
  end

  test "sync/1 puts the closed chunks in the file while it stays open", %{tmp_dir: dir} do
    {writer, path} = open!(dir, :zstd)

    {writer, schema_id} =
      Writer.add_schema(writer, "std_msgs/msg/Float64", "ros2msg", @definition)

    {writer, speed} = Writer.add_channel(writer, schema_id, "/speed", "cdr", @qos)

    writer =
      writer
      |> Writer.write_message(speed, 0, 1_000, 900, "speed 0")
      |> Writer.close_chunk()
      |> Writer.sync()

    assert [%{data: "speed 0", log_time: 1_000}] =
             McapReader.read_complete_chunks!(File.read!(path))

    :ok = Writer.close(writer)
  end

  test "a sync the file refuses raises File.Error", %{tmp_dir: dir} do
    {writer, path} = open!(dir, :none)
    :ok = Writer.close(writer)

    assert_raise File.Error, ~r/#{Regex.escape(path)}/, fn -> Writer.sync(writer) end
  end

  test "abandon/1 closes the file as written, without its open chunk or summary",
       %{tmp_dir: dir} do
    {writer, path} = open!(dir, :zstd)
    {writer, %{messages: [first, second | _messages]}} = three_chunks(writer)
    writer = Writer.write_message(writer, first.channel_id, 9, 9_000, 9_000, "open chunk")

    :ok = Writer.abandon(writer)

    bytes = File.read!(path)

    assert [^first, ^second | _messages] =
             bytes |> McapReader.read_complete_chunks!() |> without_chunk()

    refute Enum.any?(McapReader.read_complete_chunks!(bytes), &(&1.data == "open chunk"))
    refute String.ends_with?(bytes, <<0x89, "MCAP0\r\n">>)
  end

  test "attachments and metadata read back with their indexes", %{tmp_dir: dir} do
    {writer, path} = open!(dir, :zstd)

    file =
      writer
      |> Writer.add_attachment("stereo.yml", "application/yaml", 1_000, 900, ["left: ", "1\n"])
      |> Writer.add_metadata("recording", %{"preset" => "replay", "clock" => "system"})
      |> close!(path)
      |> McapReader.read!()

    assert [
             %{
               name: "stereo.yml",
               media_type: "application/yaml",
               log_time: 1_000,
               create_time: 900,
               data: "left: 1\n"
             }
           ] = file.attachments

    assert [%{name: "recording", metadata: %{"preset" => "replay", "clock" => "system"}}] =
             file.metadata

    assert [%{name: "stereo.yml", data_size: 8}] = file.summary.attachment_indexes
    assert [%{name: "recording"}] = file.summary.metadata_indexes
    assert %{attachment_count: 1, metadata_count: 1} = file.summary.statistics
  end

  test "a channel added while a chunk is open lands before its first message", %{tmp_dir: dir} do
    {writer, path} = open!(dir, :zstd)

    {writer, schema_id} =
      Writer.add_schema(writer, "std_msgs/msg/Float64", "ros2msg", @definition)

    {writer, speed} = Writer.add_channel(writer, schema_id, "/speed", "cdr", @qos)
    writer = Writer.write_message(writer, speed, 0, 1_000, 1_000, "speed 0")
    {writer, late} = Writer.add_channel(writer, schema_id, "/late", "cdr", @qos)

    writer =
      writer |> Writer.write_message(late, 0, 1_100, 1_100, "late 0") |> Writer.close_chunk()

    file = McapReader.read!(close!(writer, path))

    %{chunk_offset: late_message_chunk} = Enum.find(file.messages, &(&1.channel_id == late))
    assert file.channel_offsets[late] < late_message_chunk
  end

  test "closing a chunk without messages writes nothing", %{tmp_dir: dir} do
    {writer, path} = open!(dir, :zstd)

    {writer, schema_id} =
      Writer.add_schema(writer, "std_msgs/msg/Float64", "ros2msg", @definition)

    {writer, _channel_id} = Writer.add_channel(writer, schema_id, "/speed", "cdr", @qos)

    assert Writer.bytes_written(Writer.close_chunk(writer)) == Writer.bytes_written(writer)
    assert %{chunks: [], messages: []} = McapReader.read!(close!(writer, path))
  end

  test "counts the bytes written to the file, the open chunk aside", %{tmp_dir: dir} do
    {writer, path} = open!(dir, :zstd)

    {writer, schema_id} =
      Writer.add_schema(writer, "std_msgs/msg/Float64", "ros2msg", @definition)

    {writer, channel_id} = Writer.add_channel(writer, schema_id, "/speed", "cdr", @qos)
    before_chunk = Writer.bytes_written(writer)
    writer = Writer.write_message(writer, channel_id, 0, 1_000, 1_000, "speed 0")

    assert Writer.bytes_written(writer) == before_chunk

    writer = Writer.close_chunk(writer)
    %{chunks: [chunk]} = McapReader.read!(close!(writer, path))

    assert before_chunk == chunk.offset

    assert Writer.bytes_written(writer) ==
             chunk.offset + chunk.length + chunk.message_index_length
  end

  describe "on a disk that refuses writes" do
    defp open_full! do
      {:ok, writer} = Writer.open("/dev/full", compression: :none)

      {writer, schema_id} =
        Writer.add_schema(writer, "std_msgs/msg/Float64", "ros2msg", @definition)

      {writer, channel_id} = Writer.add_channel(writer, schema_id, "/image", "cdr", @qos)
      {writer, channel_id}
    end

    test "close answers the error of the writes it held back" do
      {writer, _channel_id} = open_full!()

      assert {:error, :enospc} = Writer.close(writer)
    end

    test "close answers the error of writing the open chunk" do
      {writer, channel_id} = open_full!()
      frame = :binary.copy(<<7>>, 2_000_000)

      writer = Writer.write_message(writer, channel_id, 0, 1_000, 1_000, frame)

      assert {:error, :enospc} = Writer.close(writer)
    end

    test "closing a chunk the disk refuses raises" do
      {writer, channel_id} = open_full!()
      frame = :binary.copy(<<7>>, 2_000_000)
      writer = Writer.write_message(writer, channel_id, 0, 1_000, 1_000, frame)

      assert_raise File.Error, ~r/no space left on device/, fn -> Writer.close_chunk(writer) end
    end
  end

  test "a file that cannot be created is an error", %{tmp_dir: dir} do
    assert {:error, :enoent} = Writer.open(Path.join([dir, "missing", "a.mcap"]), [])
  end
end

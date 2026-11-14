defmodule VisionCore.Mcap.RecordTest do
  use ExUnit.Case, async: true

  alias VisionCore.Mcap.Record

  # The layouts of https://mcap.dev/spec: <opcode><uint64 content length><content>,
  # little-endian, strings and maps prefixed by their uint32 byte length.
  defp encoded(iodata), do: IO.iodata_to_binary(iodata)

  test "the magic is 0x89 MCAP0 CR LF" do
    assert encoded(Record.magic()) == <<0x89, "MCAP", 0x30, "\r\n">>
  end

  test "a header holds the profile and the library" do
    assert encoded(Record.header("ros2", "ovcs vision")) ==
             <<0x01, 23::little-64, 4::little-32, "ros2", 11::little-32, "ovcs vision">>
  end

  test "a footer's CRC continues the summary's over its own fields before the CRC" do
    summary = "summary records"
    fields = <<0x02, 20::little-64, 100::little-64, 200::little-64>>

    assert encoded(Record.footer(100, 200, :erlang.crc32(summary))) ==
             fields <> <<:erlang.crc32(summary <> fields)::little-32>>
  end

  test "a schema holds its id, name, encoding and data" do
    assert encoded(Record.schema(1, "std_msgs/msg/Float64", "ros2msg", "float64 data\n")) ==
             <<0x03, 54::little-64, 1::little-16, 20::little-32, "std_msgs/msg/Float64",
               7::little-32, "ros2msg", 13::little-32, "float64 data\n">>
  end

  test "a channel holds its ids, topic, encoding and metadata ordered by key" do
    metadata = %{"b" => "2", "a" => "1"}

    assert encoded(Record.channel(3, 1, "/tf", "cdr", metadata)) ==
             <<0x04, 42::little-64, 3::little-16, 1::little-16, 3::little-32, "/tf", 3::little-32,
               "cdr", 20::little-32, 1::little-32, "a", 1::little-32, "1", 1::little-32, "b",
               1::little-32, "2">>
  end

  test "a message holds its channel, sequence, times and bytes" do
    assert encoded(Record.message(3, 7, 1_000, 900, ["ab", "c"])) ==
             <<0x05, 25::little-64, 3::little-16, 7::little-32, 1_000::little-64, 900::little-64,
               "abc">>
  end

  test "a chunk names its compression and prefixes its records with their uint64 length" do
    assert encoded(Record.chunk(10, 20, 6, 1234, :zstd, ["xy", "z"])) ==
             <<0x06, 47::little-64, 10::little-64, 20::little-64, 6::little-64, 1234::little-32,
               4::little-32, "zstd", 3::little-64, "xyz">>
  end

  test "an uncompressed chunk names an empty compression" do
    assert encoded(Record.chunk(10, 20, 3, 1234, :none, "xyz")) ==
             <<0x06, 43::little-64, 10::little-64, 20::little-64, 3::little-64, 1234::little-32,
               0::little-32, 3::little-64, "xyz">>
  end

  test "a message index lists each message's log time and offset" do
    assert encoded(Record.message_index(3, [{10, 0}, {20, 56}])) ==
             <<0x07, 38::little-64, 3::little-16, 32::little-32, 10::little-64, 0::little-64,
               20::little-64, 56::little-64>>
  end

  test "a chunk index locates its chunk and its message indexes ordered by channel" do
    chunk_index = %{
      message_start_time: 10,
      message_end_time: 20,
      chunk_start_offset: 100,
      chunk_length: 80,
      message_index_offsets: %{4 => 200, 3 => 180},
      message_index_length: 40,
      compression: :zstd,
      compressed_size: 30,
      uncompressed_size: 60
    }

    assert encoded(Record.chunk_index(chunk_index)) ==
             <<0x08, 88::little-64, 10::little-64, 20::little-64, 100::little-64, 80::little-64,
               20::little-32, 3::little-16, 180::little-64, 4::little-16, 200::little-64,
               40::little-64, 4::little-32, "zstd", 30::little-64, 60::little-64>>
  end

  test "an attachment's CRC covers its fields before the CRC" do
    fields =
      <<1_000::little-64, 900::little-64, 5::little-32, "a.yml", 10::little-32, "text/plain",
        3::little-64, "k:v">>

    assert encoded(Record.attachment(1_000, 900, "a.yml", "text/plain", "k:v")) ==
             <<0x09, byte_size(fields) + 4::little-64>> <>
               fields <> <<:erlang.crc32(fields)::little-32>>
  end

  test "an attachment index locates its attachment" do
    attachment_index = %{
      offset: 100,
      length: 60,
      log_time: 1_000,
      create_time: 900,
      data_size: 3,
      name: "a.yml",
      media_type: "text/plain"
    }

    assert encoded(Record.attachment_index(attachment_index)) ==
             <<0x0A, 63::little-64, 100::little-64, 60::little-64, 1_000::little-64,
               900::little-64, 3::little-64, 5::little-32, "a.yml", 10::little-32, "text/plain">>
  end

  test "a metadata record holds its name and map ordered by key" do
    assert encoded(Record.metadata("rec", %{"z" => "", "preset" => "replay"})) ==
             <<0x0C, 40::little-64, 3::little-32, "rec", 29::little-32, 6::little-32, "preset",
               6::little-32, "replay", 1::little-32, "z", 0::little-32>>
  end

  test "a metadata index locates its metadata record" do
    assert encoded(Record.metadata_index(100, 48, "rec")) ==
             <<0x0D, 23::little-64, 100::little-64, 48::little-64, 3::little-32, "rec">>
  end

  test "a data end holds the data section's CRC" do
    assert encoded(Record.data_end(0xDEADBEEF)) ==
             <<0x0F, 4::little-64, 0xDEADBEEF::little-32>>
  end

  test "statistics hold the counts, the time range and each channel's message count" do
    statistics = %{
      message_count: 5,
      schema_count: 1,
      channel_count: 2,
      attachment_count: 1,
      metadata_count: 1,
      chunk_count: 3,
      message_start_time: 10,
      message_end_time: 50,
      channel_message_counts: %{2 => 2, 1 => 3}
    }

    assert encoded(Record.statistics(statistics)) ==
             <<0x0B, 66::little-64, 5::little-64, 1::little-16, 2::little-32, 1::little-32,
               1::little-32, 3::little-32, 10::little-64, 50::little-64, 20::little-32,
               1::little-16, 3::little-64, 2::little-16, 2::little-64>>
  end

  test "a summary offset locates a group of summary records by their opcode" do
    for {group, opcode} <- [
          schema: 0x03,
          channel: 0x04,
          chunk_index: 0x08,
          attachment_index: 0x0A,
          metadata_index: 0x0D,
          statistics: 0x0B
        ] do
      assert encoded(Record.summary_offset(group, 100, 50)) ==
               <<0x0E, 17::little-64, opcode, 100::little-64, 50::little-64>>
    end
  end
end

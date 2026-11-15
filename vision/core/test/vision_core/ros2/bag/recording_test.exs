defmodule VisionCore.Ros2.Bag.RecordingTest do
  use ExUnit.Case, async: true

  defmodule DropOnLookup do
    @moduledoc """
    A name for a `VisionCore.Disks` at which each lookup by a recording
    hands that recording a message it drops, its queue being 0, and counts it.
    """
    alias Ros2Zenoh.StdMsgs.Msg.Float64
    alias VisionCore.Ros2.Bag.Recording

    def whereis_name({disks, lookups}) do
      if Recording.status(self()) do
        :ok = Recording.write(self(), "/speed", Float64, %Float64{data: 0.0}, 0)
        :counters.add(lookups, 1, 1)
      end

      disks
    end
  end

  alias Ros2Zenoh.BuiltinInterfaces.Msg.Time
  alias Ros2Zenoh.RmwZenoh
  alias Ros2Zenoh.SensorMsgs.Msg.Image
  alias Ros2Zenoh.StdMsgs.Msg.Float64
  alias Ros2Zenoh.StdMsgs.Msg.Header
  alias VisionCore.{Disk, Disks, McapReader, TestDisks}
  alias VisionCore.Ros2.Bag.Metadata
  alias VisionCore.Ros2.Bag.Recording

  @moduletag :tmp_dir

  # Long enough that no chunk closes on its own in a test that does not wait for one.
  @no_chunk_close [chunk_interval_ms: 60_000]

  defp start!(dir, opts), do: start_supervised!({Recording, recording_options(dir, opts)})

  # Linked to the test process, which does not trap exits: a crash would end the test.
  defp start_linked!(dir, opts) do
    {:ok, pid} = Recording.start_link(recording_options(dir, opts))
    pid
  end

  defp recording_options(dir, opts),
    do: Keyword.merge([dir: bag_dir(dir), name: "bag", start_time_ns: 0], opts)

  defp bag_dir(dir), do: Path.join(dir, "bag")
  defp file_path(dir, index), do: Path.join(bag_dir(dir), "bag_#{index}.mcap")
  defp read_file!(dir, index), do: McapReader.read!(File.read!(file_path(dir, index)))

  defp metadata_yaml!(dir) do
    bag_dir(dir)
    |> Path.join("metadata.yaml")
    |> YamlElixir.read_from_file!()
    |> Map.fetch!("rosbag2_bagfile_information")
  end

  defp speed(data), do: %Float64{data: data}

  # Past the writer's 1 MiB of held back writes: its chunk's write fails at once on a full disk.
  defp large_image do
    %Image{
      header: %Header{stamp: %Time{sec: 0, nanosec: 0}, frame_id: "left"},
      height: 1_000,
      width: 2_000,
      encoding: "mono8",
      step: 2_000,
      data: :binary.copy(<<7>>, 2_000_000)
    }
  end

  defp image(sec) do
    %Image{
      header: %Header{stamp: %Time{sec: sec, nanosec: 0}, frame_id: "left"},
      height: 2,
      width: 3,
      encoding: "mono8",
      step: 3,
      data: <<sec, 1, 2, 3, 4, 5>>
    }
  end

  # {topic, sequence, log time, publish time, payload} of a file's messages, in order.
  defp messages(file) do
    for message <- file.messages do
      {file.channels[message.channel_id].topic, message.sequence, message.log_time,
       message.publish_time, message.data}
    end
  end

  defp complete?(dir, index) do
    match?(%{}, read_file!(dir, index))
  rescue
    _error -> false
  end

  # Raw, so that the open waiting for the writer does not hold the file server.
  defp read_pipe!(path) do
    {:ok, pipe} = :file.open(path, [:raw, :read, :binary])
    read_to_end!(pipe, [])
  end

  defp read_to_end!(pipe, read) do
    case :file.read(pipe, 65_536) do
      {:ok, bytes} -> read_to_end!(pipe, [read | bytes])
      :eof -> IO.iodata_to_binary(read)
    end
  end

  defp eventually(check, attempts \\ 200) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("the condition never held")
      true -> Process.sleep(5) && eventually(check, attempts - 1)
    end
  end

  test "writes each message as rosbag2 stores it, with its schema and channel", %{tmp_dir: dir} do
    pid = start!(dir, @no_chunk_close)

    :ok = Recording.write(pid, "speed", Float64, speed(1.5), 1_000)
    :ok = Recording.write(pid, "/left/image_raw", Image, image(7), 1_100)
    :ok = Recording.write(pid, "/speed", Float64, speed(2.5), 1_200)
    :ok = Recording.stop(pid)

    file = read_file!(dir, 0)

    assert messages(file) == [
             {"/speed", 0, 1_000, 1_000, RmwZenoh.encode_payload(speed(1.5))},
             {"/left/image_raw", 0, 1_100, 1_100, RmwZenoh.encode_payload(image(7))},
             {"/speed", 1, 1_200, 1_200, RmwZenoh.encode_payload(speed(2.5))}
           ]

    assert <<0, 1, 0, 0, _body::binary>> = hd(file.messages).data
    assert file.header.profile == "ros2"

    assert file.schemas |> Map.values() |> Enum.sort() == [
             %{
               name: "sensor_msgs/msg/Image",
               encoding: "ros2msg",
               data: Ros2Zenoh.definition(Image)
             },
             %{
               name: "std_msgs/msg/Float64",
               encoding: "ros2msg",
               data: Ros2Zenoh.definition(Float64)
             }
           ]

    qos = Metadata.encode_qos_profiles([Metadata.publisher_qos()])

    assert [speed_channel] =
             for({_id, %{topic: "/speed"} = channel} <- file.channels, do: channel)

    assert file.schemas[speed_channel.schema_id].name == "std_msgs/msg/Float64"
    assert speed_channel.message_encoding == "cdr"

    assert speed_channel.metadata == %{
             "offered_qos_profiles" => qos,
             "topic_type_hash" => Float64.type_hash()
           }
  end

  test "a log time earlier than one written before is raised to it, the publish time kept",
       %{tmp_dir: dir} do
    pid = start!(dir, @no_chunk_close)

    :ok = Recording.write(pid, "/a", Float64, speed(1.0), 2_000)
    :ok = Recording.write(pid, "/b", Float64, speed(2.0), 1_000)
    :ok = Recording.write(pid, "/a", Float64, speed(3.0), 1_500)
    :ok = Recording.write(pid, "/b", Float64, speed(4.0), 3_000)
    :ok = Recording.stop(pid)

    assert for(
             {topic, _sequence, log_time, publish_time, _payload} <- messages(read_file!(dir, 0)),
             do: {topic, log_time, publish_time}
           ) ==
             [
               {"/a", 2_000, 2_000},
               {"/b", 2_000, 1_000},
               {"/a", 2_000, 1_500},
               {"/b", 3_000, 3_000}
             ]
  end

  test "a closed chunk is synced to the file while the recording goes on", %{tmp_dir: dir} do
    pid = start!(dir, chunk_interval_ms: 1)

    :ok = Recording.write(pid, "/speed", Float64, speed(1.5), 1_000)

    eventually(fn ->
      case File.read!(file_path(dir, 0)) do
        "" -> false
        bytes -> match?([_], McapReader.read_complete_chunks!(bytes))
      end
    end)

    assert Process.alive?(pid)
    :ok = Recording.stop(pid)
  end

  test "a chunk spans at most the interval of log time, however late its messages are written",
       %{tmp_dir: dir} do
    pid = start!(dir, chunk_interval_ms: 1_000, queue: 1_000)

    depth = %{
      image(0)
      | height: 320,
        width: 640,
        step: 1_280,
        data: :crypto.strong_rand_bytes(409_600)
    }

    # Three seconds of 60 Hz images waiting together, as behind a slow close and sync.
    :ok = :sys.suspend(pid)

    for n <- 0..179,
        do: :ok = Recording.write(pid, "/depth", Image, depth, div(n * 1_000_000_000, 60))

    :ok = :sys.resume(pid)
    :ok = Recording.stop(pid)

    file = read_file!(dir, 0)
    assert length(file.messages) == 180

    for chunk <- file.chunks,
        do: assert(chunk.message_end_time - chunk.message_start_time < 1_000_000_000)
  end

  describe "past max_file_bytes" do
    setup %{tmp_dir: dir} do
      pid =
        start!(dir,
          max_file_bytes: 1,
          chunk_interval_ms: 1,
          attachments: [{"left.yaml", "application/yaml", "fx: 1\n"}],
          start_time_ns: 500,
          metadata: %{"preset" => "replay"}
        )

      written = [
        {"/speed", Float64, speed(1.0), 1_000},
        {"/left/image_raw", Image, image(1), 2_000},
        {"/speed", Float64, speed(2.0), 3_000}
      ]

      for {{topic, module, message, log_time}, index} <- Enum.with_index(written) do
        :ok = Recording.write(pid, topic, module, message, log_time)
        eventually(fn -> complete?(dir, index) end)
      end

      :ok = Recording.stop(pid)
      %{written: written}
    end

    test "the recording goes on in the next file, each with its schemas and channels",
         %{tmp_dir: dir, written: written} do
      files = for index <- 0..2, do: read_file!(dir, index)
      refute File.exists?(file_path(dir, 3))

      assert Enum.flat_map(files, &messages/1) ==
               for(
                 {{topic, _module, message, log_time}, sequence} <-
                   Enum.zip(written, [0, 0, 1]),
                 do: {topic, sequence, log_time, log_time, RmwZenoh.encode_payload(message)}
               )

      for file <- files do
        assert [channel] = Map.values(file.channels)
        assert [%{name: name}] = Map.values(file.schemas)
        assert file.schemas[channel.schema_id].name == name
      end
    end

    test "the attachments and metadata go in the first file only, at the start time",
         %{tmp_dir: dir} do
      [first, second, third] = for index <- 0..2, do: read_file!(dir, index)

      assert [
               %{
                 name: "left.yaml",
                 media_type: "application/yaml",
                 data: "fx: 1\n",
                 log_time: 500,
                 create_time: 500
               }
             ] = first.attachments

      assert [%{name: "recording", metadata: %{"preset" => "replay"}}] = first.metadata
      assert second.attachments == [] and third.attachments == []
      assert second.metadata == [] and third.metadata == []
    end

    test "metadata.yaml lists every file and count", %{tmp_dir: dir} do
      yaml = metadata_yaml!(dir)

      assert yaml["version"] == 9
      assert yaml["storage_identifier"] == "mcap"
      assert yaml["relative_file_paths"] == ["bag_0.mcap", "bag_1.mcap", "bag_2.mcap"]
      assert yaml["message_count"] == 3
      assert yaml["starting_time"] == %{"nanoseconds_since_epoch" => 1_000}
      assert yaml["duration"] == %{"nanoseconds" => 2_000}

      assert for(
               file <- yaml["files"],
               do: {file["path"], file["message_count"], file["starting_time"]}
             ) ==
               [
                 {"bag_0.mcap", 1, %{"nanoseconds_since_epoch" => 1_000}},
                 {"bag_1.mcap", 1, %{"nanoseconds_since_epoch" => 2_000}},
                 {"bag_2.mcap", 1, %{"nanoseconds_since_epoch" => 3_000}}
               ]

      assert for(
               topic <- yaml["topics_with_message_count"],
               do:
                 {topic["topic_metadata"]["name"], topic["topic_metadata"]["type"],
                  topic["message_count"]}
             ) ==
               [
                 {"/left/image_raw", "sensor_msgs/msg/Image", 1},
                 {"/speed", "std_msgs/msg/Float64", 2}
               ]

      assert yaml["custom_data"] == %{"preset" => "replay"}
    end
  end

  test "past its queue, a write is dropped and counted per topic", %{tmp_dir: dir} do
    pid = start!(dir, [queue: 2] ++ @no_chunk_close)
    :ok = :sys.suspend(pid)

    for n <- 1..5, do: :ok = Recording.write(pid, "/speed", Float64, speed(n), n)
    :ok = Recording.write(pid, "/steering", Float64, speed(0), 6)

    assert %{dropped: %{"/speed" => 3, "/steering" => 1}} = Recording.status(pid)

    :ok = :sys.resume(pid)
    :ok = Recording.stop(pid)

    assert length(read_file!(dir, 0).messages) == 2

    # Plain, as yaml-cpp writes them, so a YAML parser reads numbers.
    assert metadata_yaml!(dir)["custom_data"] == %{
             "dropped:/speed" => 3,
             "dropped:/steering" => 1
           }
  end

  test "status/1 counts the bytes, files and messages", %{tmp_dir: dir} do
    pid = start!(dir, chunk_interval_ms: 1)

    :ok = Recording.write(pid, "/speed", Float64, speed(1.0), 1_000)
    :ok = Recording.write(pid, "/speed", Float64, speed(2.0), 2_000)
    :ok = Recording.write(pid, "/left/image_raw", Image, image(1), 3_000)

    eventually(fn ->
      bytes = File.read!(file_path(dir, 0))

      bytes != "" and length(McapReader.read_complete_chunks!(bytes)) == 3 and
        Recording.status(pid).bytes == byte_size(bytes)
    end)

    assert %{
             files: 1,
             messages: %{"/speed" => 2, "/left/image_raw" => 1},
             dropped: %{},
             error: nil
           } = Recording.status(pid)

    :ok = Recording.stop(pid)
  end

  test "a stop with no messages leaves a valid empty bag", %{tmp_dir: dir} do
    pid = start!(dir, @no_chunk_close)
    :ok = Recording.stop(pid)

    file = read_file!(dir, 0)
    assert file.messages == [] and file.channels == %{}

    yaml = metadata_yaml!(dir)
    assert yaml["message_count"] == 0
    assert yaml["topics_with_message_count"] == []
    assert yaml["relative_file_paths"] == ["bag_0.mcap"]
    assert [%{"path" => "bag_0.mcap", "message_count" => 0}] = yaml["files"]
  end

  @tag :capture_log
  test "a message that does not encode is dropped and counted", %{tmp_dir: dir} do
    pid = start!(dir, @no_chunk_close)

    :ok = Recording.write(pid, "/speed", Float64, %Float64{data: "fast"}, 1_000)
    :ok = Recording.write(pid, "/speed", Float64, speed(1.0), 2_000)
    _state = :sys.get_state(pid)

    assert %{dropped: %{"/speed" => 1}, messages: %{"/speed" => 1}} = Recording.status(pid)
    :ok = Recording.stop(pid)
  end

  describe "a write the disk refuses" do
    @describetag :capture_log

    test "ends the recording, its reason in the status, without crashing the caller",
         %{tmp_dir: dir} do
      File.mkdir_p!(bag_dir(dir))
      File.ln_s!("/dev/full", file_path(dir, 0))
      pid = start_linked!(dir, chunk_interval_ms: 1)

      :ok = Recording.write(pid, "/speed", Float64, speed(1.0), 1_000)
      eventually(fn -> Recording.status(pid).error != nil end)

      assert Recording.status(pid).error =~ "no space left on device"
      assert Process.alive?(pid)

      :ok = Recording.write(pid, "/speed", Float64, speed(2.0), 2_000)
      _state = :sys.get_state(pid)
      assert %{dropped: %{"/speed" => 1}} = Recording.status(pid)

      ref = Process.monitor(pid)
      :ok = Recording.stop(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert [%{"path" => "bag_0.mcap"}] = metadata_yaml!(dir)["files"]
    end

    test "on the next file ends the recording, the files before it whole", %{tmp_dir: dir} do
      File.mkdir_p!(file_path(dir, 1))
      pid = start_linked!(dir, max_file_bytes: 1, chunk_interval_ms: 1)

      :ok = Recording.write(pid, "/speed", Float64, speed(1.0), 1_000)
      eventually(fn -> complete?(dir, 0) end)
      :ok = Recording.write(pid, "/speed", Float64, speed(2.0), 2_000)
      eventually(fn -> Recording.status(pid).error != nil end)

      assert Recording.status(pid).error =~ file_path(dir, 1)
      assert [{"/speed", 0, 1_000, 1_000, _payload}] = messages(read_file!(dir, 0))
      assert [%{"path" => "bag_0.mcap", "message_count" => 1}] = metadata_yaml!(dir)["files"]
      :ok = Recording.stop(pid)
    end

    test "reports the end only once metadata.yaml is rewritten", %{tmp_dir: dir} do
      File.mkdir_p!(file_path(dir, 1))
      # Past a pipe's buffer, so the rewrite waits for this test to read it.
      metadata = %{"notes" => String.duplicate("x", 1_048_576)}
      pid = start_linked!(dir, max_file_bytes: 1, chunk_interval_ms: 1, metadata: metadata)

      :ok = Recording.write(pid, "/speed", Float64, speed(1.0), 1_000)
      eventually(fn -> complete?(dir, 0) end)
      rewrite = Path.join(bag_dir(dir), "metadata.yaml.tmp")
      {_output, 0} = System.cmd("mkfifo", [rewrite])
      :ok = Recording.write(pid, "/speed", Float64, speed(2.0), 2_000)

      rewriting = File.open!(rewrite, [:read, :binary])
      assert Recording.status(pid).error == nil

      assert IO.binread(rewriting, :eof) =~ "message_count: 1"
      eventually(fn -> Recording.status(pid).error != nil end)
      :ok = Recording.stop(pid)
    end

    test "a sync refused after its chunk is written leaves the file with that chunk once",
         %{tmp_dir: dir} do
      # A pipe takes the writes and refuses the sync; the test reads the file through it.
      File.mkdir_p!(bag_dir(dir))
      {_output, 0} = System.cmd("mkfifo", [file_path(dir, 0)])
      reader = Task.async(fn -> read_pipe!(file_path(dir, 0)) end)
      pid = start_linked!(dir, chunk_interval_ms: 1)

      :ok = Recording.write(pid, "/speed", Float64, speed(1.0), 1_000)
      eventually(fn -> Recording.status(pid).error != nil end)

      assert Recording.status(pid).error =~ "sync"
      assert [%{log_time: 1_000}] = reader |> Task.await() |> McapReader.read_complete_chunks!()
      :ok = Recording.stop(pid)
    end

    test "does not count the messages of the chunk it loses", %{tmp_dir: dir} do
      pid = start_linked!(dir, compression: :none, max_file_bytes: 1, chunk_interval_ms: 1_000)
      :ok = Recording.write(pid, "/speed", Float64, speed(1.0), 0)
      File.ln_s!("/dev/full", file_path(dir, 1))
      :ok = Recording.write(pid, "/left/image_raw", Image, large_image(), 2_000_000_000)
      :ok = Recording.write(pid, "/speed", Float64, speed(3.0), 4_000_000_000)
      eventually(fn -> Recording.status(pid).error != nil end)

      assert Recording.status(pid).messages == %{"/speed" => 1}
      assert metadata_yaml!(dir)["message_count"] == 1
      :ok = Recording.stop(pid)
    end

    test "at the start refuses a folder whose parent is missing, as on a disk not mounted",
         %{tmp_dir: dir} do
      unmounted = Path.join([dir, "disks", "stick", "recordings"])
      pid = start_linked!(unmounted, @no_chunk_close)

      assert Recording.status(pid).error =~ bag_dir(unmounted)
      refute File.exists?(Path.join(dir, "disks"))
      :ok = Recording.stop(pid)
    end

    test "at the start leaves a recording that only reports it", %{tmp_dir: dir} do
      File.write!(bag_dir(dir), "a file where the folder goes")
      pid = start_linked!(dir, @no_chunk_close)

      assert Recording.status(pid).error =~ bag_dir(dir)
      :ok = Recording.write(pid, "/speed", Float64, speed(1.0), 1_000)

      ref = Process.monitor(pid)
      :ok = Recording.stop(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end
  end

  test "a recording that has stopped takes writes, status and stop without raising",
       %{tmp_dir: dir} do
    pid = start!(dir, @no_chunk_close)
    :ok = Recording.stop(pid)

    assert Recording.write(pid, "/speed", Float64, speed(1.0), 1_000) == :ok
    assert Recording.status(pid) == nil
    assert Recording.stop(pid) == :ok
  end

  test "the recording closes its file when the process that started it exits", %{tmp_dir: dir} do
    test = self()

    starter =
      spawn(fn ->
        pid = start_linked!(dir, @no_chunk_close)
        :ok = Recording.write(pid, "/speed", Float64, speed(1.0), 1_000)
        send(test, {:recording, pid})
        receive do: (:exit -> exit(:shutdown))
      end)

    assert_receive {:recording, pid}
    ref = Process.monitor(pid)
    send(starter, :exit)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

    assert [{"/speed", 0, 1_000, 1_000, _payload}] = messages(read_file!(dir, 0))
    assert metadata_yaml!(dir)["message_count"] == 1
  end

  describe "on disks" do
    @describetag :capture_log

    @stick "c8803634-2bd4-4a62-8a68-ad456f6a52ce"
    @floor_bytes 1_000_000

    # The USB stick first, then the unit's storage.
    setup %{tmp_dir: dir} do
      disks = dir |> TestDisks.setup!() |> TestDisks.start!()
      TestDisks.plug(disks, "sda1", TestDisks.f2fs_image(@stick, "ovcs-recordings"))

      eventually(fn ->
        match?({:ok, %Disk{state: :mounted}}, Disks.fetch(disks.server, @stick))
      end)

      :ok = Disks.put_order(disks.server, [@stick, "internal"])
      {:ok, stick} = Disks.fetch(disks.server, @stick)
      %{disks: disks, stick: stick}
    end

    defp start_on!(disks, disk, opts) do
      start_supervised!(
        {Recording,
         [
           dir: Path.join(disk.recordings_path, "bag"),
           name: "bag",
           disks: disks.server,
           disk: disk.uuid,
           free_floor_bytes: @floor_bytes,
           attachments: [{"left.yaml", "application/yaml", "fx: 1\n"}],
           metadata: %{"preset" => "replay"},
           start_time_ns: 0
         ] ++ opts}
      )
    end

    # The part's MCAP files, without a folder a test put in a file's place.
    defp part!(folder) do
      files =
        folder
        |> Path.join("*.mcap")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.sort()

      yaml = folder |> Path.join("metadata.yaml") |> YamlElixir.read_from_file!()
      {Enum.map(files, &McapReader.read!(File.read!(&1))), yaml["rosbag2_bagfile_information"]}
    end

    defp on_disk?(pid, uuid), do: match?(%{disk: ^uuid}, Recording.status(pid))

    test "below the floor, goes on in <name>_part2 on the next disk, each part a whole bag",
         %{disks: disks, stick: stick} do
      pid = start_on!(disks, stick, chunk_interval_ms: 1)
      :ok = Recording.write(pid, "/speed", Float64, speed(1.0), 1_000)
      eventually(fn -> Recording.status(pid).messages == %{"/speed" => 1} end)

      TestDisks.put_free(disks, TestDisks.mount_point(disks, @stick), @floor_bytes - 1)
      eventually(fn -> on_disk?(pid, "internal") end)
      :ok = Recording.write(pid, "/speed", Float64, speed(2.0), 2_000)
      :ok = Recording.stop(pid)

      first = Path.join(stick.recordings_path, "bag")
      second = Path.join(disks.options[:internal], "bag_part2")

      assert {[part1], %{"relative_file_paths" => ["bag_0.mcap"], "message_count" => 1}} =
               part!(first)

      assert {[part2], %{"relative_file_paths" => ["bag_part2_0.mcap"], "message_count" => 1}} =
               part!(second)

      assert [{"/speed", 0, 1_000, 1_000, _payload}] = messages(part1)
      assert [{"/speed", 0, 2_000, 2_000, _payload}] = messages(part2)

      for part <- [part1, part2] do
        assert [%{name: "left.yaml"}] = part.attachments
        assert [%{name: "recording", metadata: %{"preset" => "replay"}}] = part.metadata
        assert [%{name: "std_msgs/msg/Float64"}] = Map.values(part.schemas)
      end
    end

    test "status/1 names the disk in use and every part's folder", %{disks: disks, stick: stick} do
      pid = start_on!(disks, stick, chunk_interval_ms: 1)
      first = Path.join(stick.recordings_path, "bag")
      assert %{disk: @stick, folders: [^first]} = Recording.status(pid)

      TestDisks.put_free(disks, TestDisks.mount_point(disks, @stick), 0)
      eventually(fn -> on_disk?(pid, "internal") end)

      second = Path.join(disks.options[:internal], "bag_part2")
      assert %{folders: [^first, ^second], files: 2, error: nil} = Recording.status(pid)
      :ok = Recording.stop(pid)
    end

    test "a write the disk refuses goes on on the next disk, never back on the one it left",
         %{disks: disks, stick: stick} do
      pid = start_on!(disks, stick, max_file_bytes: 1, chunk_interval_ms: 1)
      File.mkdir_p!(Path.join([stick.recordings_path, "bag", "bag_1.mcap"]))

      :ok = Recording.write(pid, "/speed", Float64, speed(1.0), 1_000)
      eventually(fn -> complete?(stick.recordings_path, 0) end)
      :ok = Recording.write(pid, "/speed", Float64, speed(2.0), 2_000)
      eventually(fn -> on_disk?(pid, "internal") end)
      :ok = Recording.write(pid, "/speed", Float64, speed(3.0), 3_000)
      :ok = Recording.stop(pid)

      assert {[part1], _yaml} = part!(Path.join(stick.recordings_path, "bag"))
      assert [{"/speed", 0, 1_000, 1_000, _payload}] = messages(part1)

      second = Path.join(disks.options[:internal], "bag_part2")
      assert {parts, %{"message_count" => 2}} = part!(second)

      assert [2_000, 3_000] =
               for(part <- parts, {_t, _s, time, _p, _d} <- messages(part), do: time)

      assert File.ls!(stick.recordings_path) == ["bag"]
    end

    test "an ejected disk is left, its file closed, and unmounted", %{disks: disks, stick: stick} do
      pid = start_on!(disks, stick, chunk_interval_ms: 1)
      :ok = Recording.write(pid, "/speed", Float64, speed(1.0), 1_000)
      eventually(fn -> Recording.status(pid).messages == %{"/speed" => 1} end)

      assert Disks.eject(disks.server, @stick) == :ok
      eventually(fn -> on_disk?(pid, "internal") end)
      :ok = Recording.stop(pid)

      assert {:ok, %Disk{state: :ejected}} = Disks.fetch(disks.server, @stick)
      assert {[part1], %{"message_count" => 1}} = part!(Path.join(stick.recordings_path, "bag"))
      assert [{"/speed", 0, 1_000, 1_000, _payload}] = messages(part1)
      assert {[_part2], _yaml} = part!(Path.join(disks.options[:internal], "bag_part2"))
    end

    test "a disk pulled out is left for the next one", %{disks: disks, stick: stick} do
      pid = start_on!(disks, stick, chunk_interval_ms: 1)

      TestDisks.pull(disks, "sda1")
      eventually(fn -> on_disk?(pid, "internal") end)
      :ok = Recording.write(pid, "/speed", Float64, speed(1.0), 1_000)
      :ok = Recording.stop(pid)

      assert {[part2], _yaml} = part!(Path.join(disks.options[:internal], "bag_part2"))
      assert [{"/speed", 0, 1_000, 1_000, _payload}] = messages(part2)
    end

    test "skips a disk that holds the part's folder already, leaving the folder as it is",
         %{disks: disks, stick: stick} do
      taken = Path.join(disks.options[:internal], "bag_part2")
      File.mkdir_p!(taken)
      File.write!(Path.join(taken, "metadata.yaml"), "kept")
      pid = start_on!(disks, stick, chunk_interval_ms: 1)

      TestDisks.put_free(disks, TestDisks.mount_point(disks, @stick), 0)
      eventually(fn -> Recording.status(pid).error != nil end)

      assert Recording.status(pid).error =~ taken
      assert Recording.status(pid).error =~ "no disk"
      assert File.ls!(taken) == ["metadata.yaml"]
      assert File.read!(Path.join(taken, "metadata.yaml")) == "kept"
      :ok = Recording.stop(pid)
    end

    test "each part's metadata.yaml counts the drops of that part", %{disks: disks, stick: stick} do
      pid = start_on!(disks, stick, queue: 1, chunk_interval_ms: 1)
      :ok = :sys.suspend(pid)
      for n <- 1..3, do: :ok = Recording.write(pid, "/speed", Float64, speed(n), n)
      :ok = :sys.resume(pid)
      # The stick fills once the message taken is on it, not before.
      eventually(fn -> Recording.status(pid).messages["/speed"] == 1 end)

      TestDisks.put_free(disks, TestDisks.mount_point(disks, @stick), 0)
      eventually(fn -> on_disk?(pid, "internal") end)
      :ok = Recording.stop(pid)

      assert {_files, %{"custom_data" => %{"dropped:/speed" => 2}}} =
               part!(Path.join(stick.recordings_path, "bag"))

      assert {_files, %{"custom_data" => custom_data}} =
               part!(Path.join(disks.options[:internal], "bag_part2"))

      refute Map.has_key?(custom_data, "dropped:/speed")
    end

    test "does not count the messages of the chunk the disk it leaves lost",
         %{disks: disks, stick: stick} do
      pid =
        start_on!(disks, stick, compression: :none, max_file_bytes: 1, chunk_interval_ms: 1_000)

      :ok = Recording.write(pid, "/speed", Float64, speed(1.0), 0)
      File.ln_s!("/dev/full", Path.join([stick.recordings_path, "bag", "bag_1.mcap"]))
      :ok = Recording.write(pid, "/left/image_raw", Image, large_image(), 2_000_000_000)
      :ok = Recording.write(pid, "/speed", Float64, speed(3.0), 4_000_000_000)
      eventually(fn -> on_disk?(pid, "internal") end)
      _state = :sys.get_state(pid)

      assert Recording.status(pid).messages == %{"/speed" => 2}
      :ok = Recording.stop(pid)

      assert {_files, %{"message_count" => 1, "topics_with_message_count" => topics}} =
               part!(Path.join(stick.recordings_path, "bag"))

      assert for(%{"message_count" => count} <- topics, do: count) |> Enum.sum() == 1

      assert {_files, %{"message_count" => 1}} =
               part!(Path.join(disks.options[:internal], "bag_part2"))
    end

    test "a file closed before the disk refuses the next one is closed once, its messages kept",
         %{disks: disks, stick: stick} do
      pid = start_on!(disks, stick, max_file_bytes: 1, chunk_interval_ms: 60_000)
      File.mkdir_p!(Path.join([stick.recordings_path, "bag", "bag_1.mcap"]))
      :ok = Recording.write(pid, "/speed", Float64, speed(1.0), 0)

      # A chunk interval later: this write closes the chunk, then the file, then opens the next.
      :ok = Recording.write(pid, "/speed", Float64, speed(2.0), 61_000_000_000)
      eventually(fn -> on_disk?(pid, "internal") end)
      _state = :sys.get_state(pid)

      assert %{messages: %{"/speed" => 2}, files: 2} = Recording.status(pid)
      :ok = Recording.stop(pid)

      assert {[part1], %{"message_count" => 1, "files" => [%{"path" => "bag_0.mcap"}]}} =
               part!(Path.join(stick.recordings_path, "bag"))

      assert [{"/speed", 0, 0, 0, _payload}] = messages(part1)

      assert {[part2], %{"message_count" => 1}} =
               part!(Path.join(disks.options[:internal], "bag_part2"))

      assert [{"/speed", 0, 61_000_000_000, 61_000_000_000, _payload}] = messages(part2)
    end

    test "a file opened whose metadata.yaml the disk refuses is closed before going on",
         %{disks: disks, stick: stick} do
      pid = start_on!(disks, stick, max_file_bytes: 1, chunk_interval_ms: 60_000)
      folder = Path.join(stick.recordings_path, "bag")
      :ok = Recording.write(pid, "/speed", Float64, speed(1.0), 0)
      _state = :sys.get_state(pid)
      File.mkdir_p!(Path.join(folder, "metadata.yaml.tmp"))
      :ok = Recording.write(pid, "/speed", Float64, speed(2.0), 61_000_000_000)
      eventually(fn -> on_disk?(pid, "internal") end)
      _state = :sys.get_state(pid)

      assert %{files: 2} = Recording.status(pid)
      assert %{messages: []} = McapReader.read!(File.read!(Path.join(folder, "bag_1.mcap")))
      :ok = Recording.stop(pid)
    end

    test "with no disk left after closing a file whose metadata.yaml the disk refuses, ends",
         %{disks: disks, stick: stick} do
      :ok = Disks.put_enabled(disks.server, "internal", false)
      pid = start_on!(disks, stick, chunk_interval_ms: 1)
      :ok = Recording.write(pid, "/speed", Float64, speed(1.0), 0)
      _state = :sys.get_state(pid)
      File.mkdir_p!(Path.join([stick.recordings_path, "bag", "metadata.yaml.tmp"]))

      TestDisks.put_free(disks, TestDisks.mount_point(disks, @stick), 0)
      eventually(fn -> Recording.status(pid).error != nil end)

      assert Process.alive?(pid)
      assert {[part1], _yaml} = part!(Path.join(stick.recordings_path, "bag"))
      assert [{"/speed", 0, 0, 0, _payload}] = messages(part1)
      :ok = Recording.stop(pid)
    end

    test "counts a drop in one part, one while it goes on to the next disk too",
         %{disks: disks, stick: stick} do
      lookups = :counters.new(1, [])
      disks = %{disks | server: {:via, DropOnLookup, {disks.server, lookups}}}
      pid = start_on!(disks, stick, queue: 0, chunk_interval_ms: 1)

      TestDisks.put_free(disks, TestDisks.mount_point(disks, @stick), 0)
      eventually(fn -> on_disk?(pid, "internal") end)
      :ok = Recording.stop(pid)

      parts = [
        Path.join(stick.recordings_path, "bag"),
        Path.join(disks.options[:internal], "bag_part2")
      ]

      dropped =
        for folder <- parts do
          {_files, %{"custom_data" => custom_data}} = part!(folder)
          Map.get(custom_data, "dropped:/speed", 0)
        end

      assert Enum.sum(dropped) == :counters.get(lookups, 1)
    end

    test "with no disk left, ends saying why", %{disks: disks, stick: stick} do
      :ok = Disks.put_enabled(disks.server, "internal", false)
      pid = start_on!(disks, stick, chunk_interval_ms: 1)

      TestDisks.put_free(disks, TestDisks.mount_point(disks, @stick), 0)
      eventually(fn -> Recording.status(pid).error != nil end)

      assert Recording.status(pid).error =~ "below"
      assert Recording.status(pid).error =~ "no disk"
      assert {[_part1], _yaml} = part!(Path.join(stick.recordings_path, "bag"))
      :ok = Recording.stop(pid)
    end
  end
end

defmodule VisionCore.RecordingsTest do
  # The bag exporter records on the disks registered under their default name.
  use ExUnit.Case, async: false

  alias VisionCore.{BagTestUnit, Disks, Recording, Recordings, TestDisks}
  alias VisionCore.Exporter.Runner
  alias VisionCore.Ros2.Bag.Metadata
  alias VisionCore.Ros2.BagExporter

  @moduletag :tmp_dir
  @moduletag :capture_log

  # Answers every call of the bag exporter's functions with its option `:answer`.
  defmodule Answering do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def outputs(_options), do: []

    @impl VisionCore.Exporter
    def init(options), do: {:ok, Keyword.fetch!(options, :answer)}

    @impl VisionCore.Exporter
    def handle_output(_output, _value, answer), do: {:ok, answer}

    @impl VisionCore.Exporter
    def handle_call(_request, _from, answer), do: {:reply, answer, answer}
  end

  @stick "c8803634-2bd4-4a62-8a68-ad456f6a52ce"
  @first "20261115T090000Z_review"
  @second "20261115T100000Z_replay"

  setup %{tmp_dir: tmp_dir} do
    disks =
      tmp_dir |> Path.join("system") |> TestDisks.setup!() |> TestDisks.start!(name: Disks)

    TestDisks.plug(disks, "sda1", TestDisks.f2fs_image(@stick, "ovcs-recordings"))
    eventually(fn -> match?({:ok, %{state: :mounted}}, Disks.fetch(Disks, @stick)) end)
    {:ok, stick} = Disks.fetch(Disks, @stick)

    %{disks: disks, internal: disks.options[:internal], stick: stick.recordings_path}
  end

  defp eventually(check, attempts \\ 200) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("the condition never held")
      true -> Process.sleep(5) && eventually(check, attempts - 1)
    end
  end

  # A part as the bag exporter leaves it: its MCAP files and its metadata.yaml.
  defp write_part!(recordings, folder, opts) do
    dir = Path.join(recordings, folder)
    File.mkdir_p!(dir)
    mcap_bytes = Keyword.get(opts, :mcap_bytes, 1_000)
    File.write!(Path.join(dir, "#{folder}_0.mcap"), :binary.copy(<<0>>, mcap_bytes))

    custom_data =
      Map.merge(
        %{
          "preset" => Keyword.fetch!(opts, :preset),
          "clock" => "automatic",
          "clock_in_use" => "system",
          "clock_synchronized" => "true",
          "started_at" => Keyword.fetch!(opts, :started_at)
        },
        Keyword.get(opts, :custom_data, %{})
      )

    metadata = %{
      files: [
        %{
          path: "#{folder}_0.mcap",
          starting_time: Keyword.fetch!(opts, :starting_ns),
          duration: Keyword.fetch!(opts, :duration_ns),
          message_count: Keyword.fetch!(opts, :messages)
        }
      ],
      topics: [
        %{
          name: "/tf",
          type: "tf2_msgs/msg/TFMessage",
          type_description_hash: "",
          offered_qos_profiles: [Metadata.publisher_qos()],
          message_count: Keyword.fetch!(opts, :messages)
        }
      ],
      custom_data: custom_data,
      ros_distro: "lyrical"
    }

    File.write!(Path.join(dir, "metadata.yaml"), Metadata.encode(metadata))
    dir
  end

  defp folder_bytes(dir),
    do: dir |> File.ls!() |> Enum.map(&File.stat!(Path.join(dir, &1)).size) |> Enum.sum()

  defp two_parts!(%{internal: internal, stick: stick}) do
    first =
      write_part!(stick, @first,
        preset: "review",
        started_at: "2026-11-15T09:00:00.000000Z",
        starting_ns: 1_000_000_000,
        duration_ns: 60_000_000_000,
        messages: 600,
        custom_data: %{"dropped:/stereo/depth/image_rect" => "2"}
      )

    second =
      write_part!(internal, @first <> "_part2",
        preset: "review",
        started_at: "2026-11-15T09:00:00.000000Z",
        starting_ns: 61_500_000_000,
        duration_ns: 20_000_000_000,
        messages: 200,
        custom_data: %{
          "dropped:/stereo/depth/image_rect" => "1",
          "dropped:/tf" => "4"
        }
      )

    {first, second}
  end

  defp start_exporter! do
    options = [
      config: BagTestUnit.config(),
      free_floor_bytes: 0,
      parameters: fn -> [] end,
      clock_synchronized?: fn -> true end
    ]

    runner =
      start_supervised!(
        {Runner, exporter: BagExporter, options: options, config: options[:config]}
      )

    :sys.get_state(runner)
    runner
  end

  describe "list/1" do
    test "joins each recording's parts across the mounted disks, the newest first", context do
      {first, second} = two_parts!(context)

      write_part!(context.internal, @second,
        preset: "replay",
        started_at: "2026-11-15T10:00:00.000000Z",
        starting_ns: 0,
        duration_ns: 0,
        messages: 0
      )

      assert {:ok, [%Recording{name: @second}, recording]} = Recordings.list()

      assert %Recording{
               name: @first,
               state: :stopped,
               preset: "review",
               clock: "automatic",
               clock_in_use: "system",
               clock_synchronized: true,
               started_at: ~U[2026-11-15 09:00:00.000000Z],
               duration_ms: 80_500,
               messages: 800,
               dropped: %{"/stereo/depth/image_rect" => 3, "/tf" => 4},
               disk: nil,
               parts: [
                 %{name: @first, number: 1, folder: ^first, disk: @stick},
                 %{name: @first <> "_part2", number: 2, folder: ^second, disk: "internal"}
               ]
             } = recording

      assert Enum.map(recording.parts, & &1.bytes) == [folder_bytes(first), folder_bytes(second)]
      assert recording.bytes == folder_bytes(first) + folder_bytes(second)
    end

    test "lists a folder without metadata.yaml, what it cannot read left out", context do
      folder = Path.join(context.internal, "20261115T110000Z_review")
      File.mkdir_p!(folder)
      File.write!(Path.join(folder, "20261115T110000Z_review_0.mcap"), "cut")

      assert {:ok,
              [
                %Recording{
                  name: "20261115T110000Z_review",
                  preset: nil,
                  started_at: nil,
                  duration_ms: nil,
                  messages: nil,
                  dropped: %{},
                  bytes: 3
                }
              ]} = Recordings.list()
    end

    test "leaves out the parts on a disk that is not mounted", context do
      two_parts!(context)
      :ok = Disks.eject(Disks, @stick)

      assert {:ok, [%Recording{name: @first, parts: [%{number: 2}]}]} = Recordings.list()
    end

    test "is empty while the disks are not watched", context do
      two_parts!(context)
      TestDisks.stop!(context.disks)

      assert Recordings.list() == {:ok, []}
    end
  end

  describe "fetch/2" do
    test "answers one recording, or not found for another name", context do
      two_parts!(context)

      assert {:ok, %Recording{name: @first}} = Recordings.fetch(@first)
      assert Recordings.fetch(@first <> "_part2") == {:error, :not_found}
      assert Recordings.fetch("../system") == {:error, :not_found}
    end
  end

  describe "start/1 and stop/2" do
    test "start a recording on the bag exporter, review on the automatic clock by default",
         %{internal: internal} do
      runner = start_exporter!()

      assert {:ok, %Recording{state: :recording} = started} = Recordings.start(exporter: runner)

      assert %{preset: "review", clock: "automatic", clock_in_use: "system", disk: "internal"} =
               started

      assert [%{folder: folder, disk: "internal"}] = started.parts
      assert Path.dirname(folder) == internal

      assert {:ok, [%Recording{name: name, state: :recording, duration_ms: duration_ms}]} =
               Recordings.list(exporter: runner)

      assert name == started.name
      assert is_integer(duration_ms)

      assert {:ok, %Recording{state: :stopped, disk: nil}} =
               Recordings.stop(started.name, exporter: runner)

      assert {:ok, %Recording{state: :stopped, preset: "review"}} = Recordings.fetch(started.name)
    end

    test "start takes a preset and a clock", %{} do
      runner = start_exporter!()

      assert {:ok, %Recording{preset: "replay", clock: "since_start"} = started} =
               Recordings.start(exporter: runner, preset: :replay, clock: :since_start)

      Recordings.stop(started.name, exporter: runner)
    end

    test "start refuses while recording", %{} do
      runner = start_exporter!()
      {:ok, started} = Recordings.start(exporter: runner)

      assert Recordings.start(exporter: runner) == {:error, :busy}
      Recordings.stop(started.name, exporter: runner)
    end

    test "start answers why with no disk to record on", %{} do
      runner = start_exporter!()
      :ok = Disks.put_enabled(Disks, "internal", false)
      :ok = Disks.put_enabled(Disks, @stick, false)

      assert {:error, {:no_disk, reason}} = Recordings.start(exporter: runner)
      assert reason =~ "no disk"
    end

    test "without a bag exporter, start and stop answer so" do
      assert Recordings.start([]) == {:error, :no_bag_exporter}
      assert Recordings.stop(@first, []) == {:error, :no_bag_exporter}
    end

    test "stop refuses a recording that is stopped, and one it does not have", context do
      runner = start_exporter!()
      two_parts!(context)

      assert Recordings.stop(@first, exporter: runner) == {:error, :stopped}
      assert Recordings.stop("20261115T000000Z_review", exporter: runner) == {:error, :not_found}
    end
  end

  describe "delete/2" do
    test "removes every part of a recording", context do
      {first, second} = two_parts!(context)

      assert Recordings.delete(@first) == :ok
      refute File.exists?(first)
      refute File.exists?(second)
      assert Recordings.list() == {:ok, []}
    end

    test "refuses the recording in progress, and one it does not have", %{} do
      runner = start_exporter!()
      {:ok, started} = Recordings.start(exporter: runner)

      assert Recordings.delete(started.name, exporter: runner) == {:error, :recording}
      assert File.exists?(hd(started.parts).folder)
      assert Recordings.delete("../system", exporter: runner) == {:error, :not_found}

      Recordings.stop(started.name, exporter: runner)
    end
  end

  defp answering!(answer) do
    runner =
      start_supervised!(
        {Runner, exporter: Answering, options: [answer: answer], config: %VisionCore.Config{}},
        id: make_ref()
      )

    :sys.get_state(runner)
    runner
  end

  describe "an exporter that answers no recording" do
    test "has list and fetch answer why", context do
      two_parts!(context)

      for answer <- [{:error, :timeout}, {:error, {:failed, "crashed"}}, {:error, :unknown_call}] do
        runner = answering!(answer)

        assert Recordings.list(exporter: runner) == answer
        assert Recordings.fetch(@first, exporter: runner) == answer
      end
    end

    test "that does not run records none", context do
      two_parts!(context)
      stopped = spawn(fn -> :ok end)
      ref = Process.monitor(stopped)
      assert_receive {:DOWN, ^ref, :process, ^stopped, _reason}

      assert {:ok, [%Recording{name: @first, state: :stopped}]} =
               Recordings.list(exporter: stopped)

      assert {:ok, %Recording{state: :stopped}} = Recordings.fetch(@first, exporter: stopped)
    end
  end

  describe "an exporter that does not answer" do
    test "keeps a recording from being deleted or archived", context do
      {first, second} = two_parts!(context)
      silent = spawn_link(fn -> Process.sleep(:infinity) end)

      assert Recordings.delete(@first, exporter: silent) == {:error, :timeout}
      assert Recordings.archive(@first, exporter: silent) == {:error, :timeout}
      assert File.exists?(first) and File.exists?(second)
    end
  end

  # Files outside any recordings folder, in a folder named as a recording.
  defp outside!(tmp_dir) do
    outside = Path.join(tmp_dir, "outside")
    File.mkdir_p!(Path.join(outside, @first))
    File.write!(Path.join([outside, @first, "key.pem"]), "PRIVATE KEY")
    outside
  end

  defp refuses_everything_on(outside) do
    assert Recordings.list() == {:ok, []}
    assert Recordings.fetch(@first) == {:error, :not_found}
    assert Recordings.archive(@first) == {:error, :not_found}
    assert Recordings.delete(@first) == {:error, :not_found}
    assert File.read!(Path.join([outside, @first, "key.pem"])) == "PRIVATE KEY"
  end

  describe "a disk's links and special files" do
    test "leaves out a recordings folder that links elsewhere", %{stick: stick} = context do
      outside = outside!(context.tmp_dir)
      File.rm_rf!(stick)
      File.ln_s!(outside, stick)

      refuses_everything_on(outside)
    end

    test "leaves out a part folder that links elsewhere", %{internal: internal} = context do
      outside = outside!(context.tmp_dir)
      File.ln_s!(Path.join(outside, @first), Path.join(internal, @first))

      refuses_everything_on(outside)
    end

    test "neither counts, archives nor deletes a file a part links to", context do
      outside = outside!(context.tmp_dir)
      {first, second} = two_parts!(context)
      bytes = folder_bytes(first) + folder_bytes(second)
      File.ln_s!(Path.join([outside, @first, "key.pem"]), Path.join(first, "key.mcap"))

      assert {:ok, [%Recording{name: @first, bytes: ^bytes}]} = Recordings.list()

      {:ok, archive} = Recordings.archive(@first)
      tar = Enum.into(archive.stream, <<>>)
      assert {:ok, files} = :erl_tar.extract({:binary, tar}, [:memory])
      refute Enum.any?(files, fn {name, _bytes} -> name == ~c"#{@first}/key.mcap" end)
      refute tar =~ "PRIVATE KEY"

      assert Recordings.delete(@first) == :ok
      refute File.exists?(first)
      assert File.read!(Path.join([outside, @first, "key.pem"])) == "PRIVATE KEY"
    end

    test "reads no metadata.yaml that is not a regular file, nor archives it",
         %{internal: internal} do
      folder = Path.join(internal, @first)
      File.mkdir_p!(folder)
      File.write!(Path.join(folder, "#{@first}_0.mcap"), "cut")
      fifo = Path.join(folder, "metadata.yaml")
      {_output, 0} = System.cmd("mkfifo", [fifo])

      assert {:ok, [%Recording{name: @first, preset: nil, messages: nil, bytes: 3}]} =
               within(fn -> Recordings.list() end, fifo)

      {:ok, archive} = within(fn -> Recordings.archive(@first) end, fifo)

      assert :erl_tar.extract({:binary, Enum.into(archive.stream, <<>>)}, [:memory]) ==
               {:ok, [{~c"#{@first}/#{@first}_0.mcap", "cut"}]}
    end

    test "reads no metadata.yaml past a mebibyte", context do
      {first, _second} = two_parts!(context)
      metadata = Path.join(first, "metadata.yaml")
      File.write!(metadata, ["# ", :binary.copy("x", 1_048_576), "\n"], [:append])

      assert {:ok, [%Recording{name: @first, messages: 200}]} = Recordings.list()
    end
  end

  # What `fun` answers within a second; a writer holds `fifo` open until then, so a reader stuck on it ends.
  defp within(fun, fifo) do
    writer =
      Port.open({:spawn_executable, System.find_executable("sh")},
        args: ["-c", ~s(exec 3<>"$0"; read line), fifo]
      )

    task = Task.async(fun)
    answer = Task.yield(task, 1_000)
    Port.close(writer)

    case answer do
      {:ok, answer} ->
        answer

      nil ->
        Task.shutdown(task, :brutal_kill)
        flunk("stuck reading #{fifo}")
    end
  end

  describe "archive/2" do
    test "is the tar of a recording, each part a folder with its files", context do
      {first, second} = two_parts!(context)

      assert {:ok, %{filename: filename, size: size, stream: stream}} = Recordings.archive(@first)
      assert filename == @first <> ".tar"

      tar = Enum.into(stream, <<>>)
      assert byte_size(tar) == size
      assert {:ok, files} = :erl_tar.extract({:binary, tar}, [:memory])

      expected =
        for dir <- [first, second], file <- File.ls!(dir) do
          {~c"#{Path.basename(dir)}/#{file}", File.read!(Path.join(dir, file))}
        end

      assert Enum.sort(files) == Enum.sort(expected)
    end

    test "refuses the recording in progress, and one it does not have", %{} do
      runner = start_exporter!()
      {:ok, started} = Recordings.start(exporter: runner)

      assert Recordings.archive(started.name, exporter: runner) == {:error, :recording}
      assert Recordings.archive("unknown", exporter: runner) == {:error, :not_found}

      Recordings.stop(started.name, exporter: runner)
    end
  end
end

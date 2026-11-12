defmodule VisionCore.Camera.V4L2SingleTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias VisionCore.Camera.{Frame, V4L2Single}
  alias VisionCore.{Outputs, Timing}

  @moduletag :tmp_dir

  defp eventually(check, attempts \\ 100) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && eventually(check, attempts - 1)
    end
  end

  defp rgb_record(capture_ns, rgb \\ <<1, 2, 3, 4, 5, 6>>) do
    <<6, 2::little-16, 1::little-16, capture_ns::little-signed-64, rgb::binary>>
  end

  defp metadata_record(exposure_us, gain) do
    values =
      for field <- [exposure_us, gain, 0, 0, 0, 0, 0, 0],
          into: <<>>,
          do: <<field::little-float-64>>

    <<3, 0b11, 1_000::little-signed-64, values::binary>>
  end

  # Answers `media-ctl -p` with a CAMSS graph captured on the Arduino VENTUNO Q, whose CSI PHY 2
  # has an IMX477, and sends the test every other media-ctl call's arguments.
  defp media_runner do
    text = File.read!(Path.expand("../../fixtures/camss/media-ctl-p.txt", __DIR__))
    test = self()

    fn _command, args ->
      if "-p" in args do
        {text, 0}
      else
        send(test, {:media_ctl, args})
        {"", 0}
      end
    end
  end

  defp write_script(tmp_dir, name, body) do
    path = Path.join(tmp_dir, name)
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    path
  end

  # A capture program that writes its arguments, one a line, then reads its stdin into `commands`.
  defp listening_program(tmp_dir) do
    arguments = Path.join(tmp_dir, "arguments.txt")
    commands = Path.join(tmp_dir, "commands.bin")

    script =
      write_script(
        tmp_dir,
        "capture.sh",
        "printf '%s\\n' \"$@\" > #{arguments}\ncat > #{commands}"
      )

    {script, arguments, commands}
  end

  defp start_camera(opts) do
    start_supervised!(
      {V4L2Single, [name: :hq, label: "hq", csiphy: 2, media_runner: media_runner()] ++ opts},
      restart: :temporary
    )
  end

  defp arguments(path) do
    eventually(fn -> File.exists?(path) and File.read!(path) =~ "--threads" end)
    path |> File.read!() |> String.split("\n", trim: true)
  end

  test "registers under the name of its label", %{tmp_dir: tmp_dir} do
    {script, _arguments, _commands} = listening_program(tmp_dir)
    camera = start_camera(executable: script)

    assert Process.whereis(V4L2Single.name_for("hq")) == camera
  end

  test "the registered name and the frame label come from :label, not :name", %{tmp_dir: tmp_dir} do
    records = Path.join(tmp_dir, "records.bin")
    record = rgb_record(5)
    File.write!(records, <<byte_size(record)::32, record::binary>>)
    script = write_script(tmp_dir, "capture.sh", "sleep 0.3\ncat #{records}\ncat > /dev/null")

    :ok = Outputs.subscribe({:camera_frame, V4L2Single.name_for("front")})

    camera =
      start_supervised!(
        {V4L2Single,
         [name: :hq, label: "front", csiphy: 2, media_runner: media_runner(), executable: script]},
        restart: :temporary
      )

    assert Process.whereis(V4L2Single.name_for("front")) == camera
    assert_receive {:"$gen_cast", {:camera_frame, %Frame{label: "front"}}}, 2_000
  end

  test "routes the sensor on its CSI PHY at the sensor size and passes the program its nodes by name",
       %{tmp_dir: tmp_dir} do
    {script, arguments, _commands} = listening_program(tmp_dir)
    start_camera(executable: script)

    assert_receive {:media_ctl,
                    ["-d", "/dev/media0", "-V", ~s("imx477 3-001a":0[fmt:SRGGB12_1X12/2028x1520])]}

    flags = arguments(arguments)

    assert Enum.take(flags, 12) == [
             "--video",
             "msm_vfe2_video0",
             "--sensor",
             "imx477 3-001a",
             "--sensor-width",
             "2028",
             "--sensor-height",
             "1520",
             "--fps",
             "15",
             "--output",
             "full"
           ]
  end

  test "asks the program for the half-size output", %{tmp_dir: tmp_dir} do
    {script, arguments, _commands} = listening_program(tmp_dir)
    start_camera(executable: script, output: :half)

    assert ["--output", "half"] = arguments |> arguments() |> Enum.slice(10, 2)
  end

  test "a camera without a :csiphy is refused, naming the option" do
    Process.flag(:trap_exit, true)

    assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
             V4L2Single.start_link(name: :hq, label: "hq", media_runner: media_runner())

    assert message =~ ":csiphy"
  end

  test "an output other than :full or :half stops the camera, saying so", %{tmp_dir: tmp_dir} do
    {script, _arguments, _commands} = listening_program(tmp_dir)
    Process.flag(:trap_exit, true)

    log =
      capture_log(fn ->
        assert {:error, message} =
                 V4L2Single.start_link(
                   name: :hq,
                   label: "hq",
                   csiphy: 2,
                   media_runner: media_runner(),
                   executable: script,
                   output: :quarter
                 )

        assert message =~ ":output is :full or :half, got :quarter"
      end)

    assert log =~ ":output is :full or :half"
  end

  test "takes each frame's size from its record, whatever the sensor mode" do
    rgb = :binary.copy(<<1, 2, 3>>, 4 * 3)

    assert {:frame, %Frame{width: 4, height: 3, rgb: ^rgb}} =
             V4L2Single.parse_record(
               <<6, 4::little-16, 3::little-16, 5::little-signed-64, rgb::binary>>
             )
  end

  test "passes every colour capture setting, defaults included, and none of the pair settings",
       %{tmp_dir: tmp_dir} do
    {script, arguments, _commands} = listening_program(tmp_dir)
    start_camera(executable: script, fps: 10, rotation: 180, red_gain: 2)

    settings =
      arguments
      |> arguments()
      |> Enum.drop(12)
      |> Enum.chunk_every(2)
      |> Map.new(&List.to_tuple/1)

    assert settings["--rotation"] == "180"
    assert settings["--black-level"] == "256"
    assert settings["--awb"] == "true"
    assert settings["--red-gain"] == "2.0"
    assert settings["--blue-gain"] == "1.0"
    assert settings["--gamma"] == "2.2"
    assert settings["--ccm"] == "true"
    assert settings["--denoise"] == "true"
    assert settings["--threads"] == "3"
    refute Map.has_key?(settings, "--focus")
    assert map_size(settings) == length(V4L2Single.control_specs())
    assert "10" in arguments(arguments)
  end

  test "converts full-size frames on 3 threads and half-size ones on 1 unless told otherwise",
       %{tmp_dir: tmp_dir} do
    threads = fn opts ->
      {script, arguments, _commands} = listening_program(tmp_dir)
      camera = start_camera([executable: script] ++ opts)
      flags = arguments(arguments)
      flag = flags |> Enum.drop_while(&(&1 != "--threads")) |> Enum.at(1)
      %{threads: control} = V4L2Single.controls(camera)
      stop_supervised!(V4L2Single)
      File.rm!(arguments)
      {flag, control}
    end

    assert %{default: nil} = Enum.find(V4L2Single.control_specs(), &(&1.key == :threads))
    assert threads.([]) == {"3", 3}
    assert threads.(output: :half) == {"1", 1}
    assert threads.(output: :half, threads: 4) == {"4", 4}

    log = capture_log(fn -> assert threads.(output: :half, threads: 9) == {"1", 1} end)
    assert log =~ "threads: invalid value 9"
  end

  test "settings become name=value commands on the program stdin, checked against their specs",
       %{tmp_dir: tmp_dir} do
    {script, _arguments, commands} = listening_program(tmp_dir)
    camera = start_camera(executable: script)

    assert {:ok, %{awb: false, red_gain: 1.5, black_level: 4000}} =
             V4L2Single.set_controls(camera, awb: false, red_gain: 1.5, black_level: 4000)

    assert %{awb: false, red_gain: 1.5, black_level: 4000, gamma: 2.2} =
             V4L2Single.controls(camera)

    eventually(fn ->
      File.read(commands) ==
        {:ok, <<9::32, "awb=false", 12::32, "red_gain=1.5", 16::32, "black_level=4000">>}
    end)

    for {controls, refused} <- [
          {[red_gain: 5.0], "red_gain"},
          {[black_level: 4095], "black_level"},
          {[focus: 400], "unknown camera setting focus"}
        ] do
      assert {:error, message} = V4L2Single.set_controls(camera, controls)
      assert message =~ refused
    end
  end

  test "drops a setting the capture program would refuse, with a warning", %{tmp_dir: tmp_dir} do
    {script, arguments, _commands} = listening_program(tmp_dir)

    log =
      capture_log(fn ->
        camera = start_camera(executable: script, blue_gain: 9.0)
        assert %{blue_gain: 1.0} = V4L2Single.controls(camera)
      end)

    assert log =~ "blue_gain: invalid value 9.0"
    assert "--blue-gain" in arguments(arguments)
    assert Enum.drop_while(arguments(arguments), &(&1 != "--blue-gain")) |> Enum.at(1) == "1.0"
  end

  test "an RGB record becomes a colour frame labelled with the camera name, carrying its frame id",
       %{tmp_dir: tmp_dir} do
    records = Path.join(tmp_dir, "records.bin")
    record = rgb_record(5)
    File.write!(records, <<byte_size(record)::32, record::binary>>)
    script = write_script(tmp_dir, "capture.sh", "sleep 0.3\ncat #{records}\ncat > /dev/null")

    :ok = Outputs.subscribe({:camera_frame, V4L2Single.name_for("hq")})
    start_camera(executable: script, frame_id: "hq_optical")

    assert_receive {:"$gen_cast", {:camera_frame, %Frame{} = frame}}, 2_000

    assert %Frame{
             label: "hq",
             frame_id: "hq_optical",
             width: 2,
             height: 1,
             rgb: <<1, 2, 3, 4, 5, 6>>,
             grey: nil,
             jpeg: nil
           } = frame

    assert_in_delta frame.capture_ns, Timing.monotonic_from_kernel(5), 1_000_000
  end

  test "parses log, metadata and malformed records" do
    assert V4L2Single.parse_record(<<2, 1, "busy">>) == {:log, :warning, "busy"}

    assert {:metadata, %{exposure_time_us: 8000, analogue_gain: 2.0}} =
             V4L2Single.parse_record(metadata_record(8_000.0, 2.0))

    assert V4L2Single.parse_record(rgb_record(5, <<1, 2, 3>>)) == {:error, :malformed_record}
    assert V4L2Single.parse_record(<<4, 2::little-16>>) == {:error, :malformed_record}
  end

  test "live is nil before any metadata and the latest record after", %{tmp_dir: tmp_dir} do
    {script, _arguments, _commands} = listening_program(tmp_dir)
    camera = start_camera(executable: script)

    assert V4L2Single.live(camera) == nil

    %{port: port} = :sys.get_state(camera)
    send(camera, {port, {:data, metadata_record(4_000.0, 4.0)}})

    assert %{exposure_time_us: 4000, analogue_gain: 4.0, received_ms: received_ms} =
             V4L2Single.live(camera)

    assert_in_delta received_ms, System.system_time(:millisecond), 1_000
  end

  test "stops when the capture program exits", %{tmp_dir: tmp_dir} do
    script = write_script(tmp_dir, "capture.sh", "exit 3")

    capture_log(fn ->
      camera = start_camera(executable: script)
      ref = Process.monitor(camera)
      assert_receive {:DOWN, ^ref, :process, _, {:v4l2_capture_exit, 3}}, 2_000
    end)
  end

  test "stops when the capture program stops delivering frames", %{tmp_dir: tmp_dir} do
    records = Path.join(tmp_dir, "records.bin")
    record = rgb_record(5)
    File.write!(records, <<byte_size(record)::32, record::binary>>)
    script = write_script(tmp_dir, "capture.sh", "cat #{records}\ncat > /dev/null")

    log =
      capture_log(fn ->
        camera = start_camera(executable: script, stall_timeout_ms: 100)
        ref = Process.monitor(camera)
        assert_receive {:DOWN, ^ref, :process, _, {:camera_stall, {:stalled, _silent_ms}}}, 3_000
      end)

    assert log =~ "stopped delivering"
  end

  test "stops when the capture program delivers no first frame", %{tmp_dir: tmp_dir} do
    script = write_script(tmp_dir, "capture.sh", "cat > /dev/null")

    capture_log(fn ->
      camera = start_camera(executable: script, startup_timeout_ms: 100)
      ref = Process.monitor(camera)

      assert_receive {:DOWN, ^ref, :process, _, {:camera_stall, {:no_first_frame, _waited_ms}}},
                     3_000
    end)
  end
end

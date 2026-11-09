defmodule VisionCore.Camera.V4L2Test do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias VisionCore.Camera.{Frame, V4L2}
  alias VisionCore.{Outputs, Timing}

  defp eventually(check, attempts \\ 100) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && eventually(check, attempts - 1)
    end
  end

  defp pair_record(left_ns, right_ns) do
    <<4, 2::little-16, 1::little-16, left_ns::little-signed-64, right_ns::little-signed-64, 1, 2,
      3, 4>>
  end

  test "port arguments carry the size, each side's nodes and every setting, defaults included" do
    arguments =
      V4L2.port_arguments(
        width: 768,
        height: 432,
        fps: 30,
        right_sensor: "imx708 7-001a",
        rotation: 180,
        analogue_gain: 2
      )

    assert Enum.take(arguments, 6) == ~w(--width 768 --height 432 --fps 30)

    {nodes, settings} =
      arguments
      |> Enum.drop(6)
      |> Enum.chunk_every(2)
      |> Map.new(fn [flag, value] -> {flag, value} end)
      |> Map.split(~w(--left-video --left-sensor --right-video --right-sensor))

    assert nodes == %{
             "--left-video" => "54080000.vi-output-0",
             "--left-sensor" => "imx708 5-001a",
             "--right-video" => "54080000.vi-output-4",
             "--right-sensor" => "imx708 7-001a"
           }

    assert settings["--rotation"] == "180"
    assert settings["--analogue-gain"] == "2.0"
    assert settings["--auto-exposure"] == "true"
    assert settings["--gamma"] == "2.2"
    assert settings["--focus"] == "428"
    assert map_size(settings) == length(V4L2.control_specs())
  end

  # Answers `media-ctl -p` with a CAMSS graph captured on the Arduino VENTUNO Q.
  defp media_runner(fixture) do
    text = File.read!(Path.expand("../../fixtures/camss/#{fixture}", __DIR__))
    fn _command, args -> if "-p" in args, do: {text, 0}, else: {"", 0} end
  end

  test "CSI PHY options route both sides and pass their nodes to the Port" do
    assert {:ok, opts} =
             V4L2.routed(
               width: 728,
               height: 544,
               fps: 30,
               left_csiphy: 0,
               right_csiphy: 1,
               media_runner: media_runner("media-ctl-p.txt")
             )

    arguments = opts |> V4L2.port_arguments() |> Enum.chunk_every(2) |> Map.new(&List.to_tuple/1)

    assert Map.take(arguments, ~w(--left-video --left-sensor --right-video --right-sensor)) == %{
             "--left-video" => "msm_vfe0_video0",
             "--left-sensor" => "imx296 5-001a",
             "--right-video" => "msm_vfe1_video0",
             "--right-sensor" => "imx296 7-001a"
           }
  end

  test "a CSI PHY without a sensor is a startup error naming the PHY" do
    Process.flag(:trap_exit, true)

    log =
      capture_log(fn ->
        assert {:error, message} =
                 V4L2.start_link(
                   label: "left",
                   width: 728,
                   height: 544,
                   fps: 30,
                   left_csiphy: 0,
                   right_csiphy: 2,
                   media_runner: media_runner("media-ctl-p-no-csiphy2-sensor.txt"),
                   executable: "/bin/true"
                 )

        assert message =~ "msm_csiphy2"
      end)

    assert log =~ "msm_csiphy2"
  end

  test "settings become name=value commands, checked against their specs" do
    assert V4L2.control_commands(rotation: 180, gamma: 1.8, auto_exposure: false) ==
             {:ok, ["rotation=180", "gamma=1.8", "auto_exposure=false"]}

    assert {:error, "rotation" <> _} = V4L2.control_commands(rotation: 90)
    assert {:error, "max_gain" <> _} = V4L2.control_commands(max_gain: 40)
    assert {:error, "unknown camera setting zoom"} = V4L2.control_commands(zoom: 2)
  end

  @tag :tmp_dir
  test "a setting changed on either side reaches the capture program", %{tmp_dir: tmp_dir} do
    commands = Path.join(tmp_dir, "commands.bin")
    script = Path.join(tmp_dir, "listen.sh")
    File.write!(script, "#!/bin/sh\ncat > #{commands}\n")
    File.chmod!(script, 0o755)

    start_supervised!(Supervisor.child_spec({V4L2, label: "right"}, id: :right))

    start_supervised!(
      Supervisor.child_spec(
        {V4L2, label: "left", executable: script, width: 2, height: 1, fps: 30},
        id: :left
      )
    )

    assert {:ok, %{gamma: 1.8}} = V4L2.set_controls(V4L2.name_for("right"), gamma: 1.8)
    assert %{gamma: 1.8, rotation: 0} = V4L2.controls(V4L2.name_for("right"))

    eventually(fn -> File.read(commands) == {:ok, <<9::32, "gamma=1.8">>} end)
  end

  @tag :tmp_dir
  test "drops a setting the capture program would refuse, with a warning", %{tmp_dir: tmp_dir} do
    arguments = Path.join(tmp_dir, "arguments.txt")
    script = Path.join(tmp_dir, "capture.sh")
    File.write!(script, "#!/bin/sh\necho \"$@\" > #{arguments}\nsleep 1\n")
    File.chmod!(script, 0o755)

    log =
      capture_log(fn ->
        start_supervised!(
          {V4L2,
           label: "left",
           executable: script,
           width: 2,
           height: 1,
           fps: 30,
           gamma: 9.0,
           rotation: 180}
        )

        eventually(fn -> File.exists?(arguments) end)
      end)

    assert log =~ "gamma: invalid value 9.0"
    assert %{gamma: 2.2, rotation: 180} = V4L2.controls(V4L2.name_for("left"))
    eventually(fn -> File.read!(arguments) =~ "--gamma 2.2" end)
  end

  test "a pair record becomes a left and a right grey frame" do
    assert {:pair, left, right} = V4L2.parse_record(pair_record(5, 6))

    assert %Frame{label: "left", width: 2, height: 1, grey: <<1, 2>>} = left
    assert %Frame{label: "right", width: 2, height: 1, grey: <<3, 4>>} = right
    # The kernel-to-Erlang offset is read on each conversion.
    assert_in_delta left.capture_ns, Timing.monotonic_from_kernel(5), 1_000_000
    assert_in_delta right.capture_ns - left.capture_ns, 1, 1_000_000
  end

  test "log and malformed records" do
    assert V4L2.parse_record(<<2, 2, "busy">>) == {:log, :error, "busy"}
    assert V4L2.parse_record(<<4, 2::little-16>>) == {:error, :malformed_record}
  end

  @tag :tmp_dir
  test "the left camera runs the capture program and hands the right frame on, each with its frame id, then stops with it",
       %{tmp_dir: tmp_dir} do
    records = Path.join(tmp_dir, "records.bin")
    record = pair_record(5, 6)
    File.write!(records, <<byte_size(record)::32, record::binary>>)
    script = Path.join(tmp_dir, "capture.sh")
    File.write!(script, "#!/bin/sh\nsleep 0.3\ncat #{records}\n")
    File.chmod!(script, 0o755)

    for label <- ["left", "right"],
        do: :ok = Outputs.subscribe({:camera_frame, V4L2.name_for(label)})

    start_supervised!(
      Supervisor.child_spec({V4L2, label: "right", frame_id: "stereo_right_optical"}, id: :right)
    )

    left =
      start_supervised!(
        Supervisor.child_spec(
          {V4L2,
           label: "left",
           frame_id: "stereo_left_optical",
           executable: script,
           width: 2,
           height: 1,
           fps: 30},
          id: :left,
          restart: :temporary
        )
      )

    ref = Process.monitor(left)

    assert_receive {:"$gen_cast",
                    {:camera_frame,
                     %Frame{label: "left", frame_id: "stereo_left_optical", grey: <<1, 2>>}}},
                   2_000

    assert_receive {:"$gen_cast",
                    {:camera_frame,
                     %Frame{label: "right", frame_id: "stereo_right_optical", grey: <<3, 4>>}}},
                   2_000

    assert_receive {:DOWN, ^ref, :process, _, {:v4l2_capture_exit, 0}}, 2_000
  end

  defp metadata_record(exposure_us, gain) do
    values =
      for field <- [exposure_us, gain, 0, 0, 0, 0, 0, 0],
          into: <<>>,
          do: <<field::little-float-64>>

    <<3, 0b11, 1_000::little-signed-64, values::binary>>
  end

  test "parses a metadata record into what the sensors apply" do
    assert {:metadata, %{exposure_time_us: 8000, analogue_gain: 2.0}} =
             V4L2.parse_record(metadata_record(8_000.0, 2.0))
  end

  @tag :tmp_dir
  test "live is nil before any metadata and the latest record after, on either side", %{
    tmp_dir: tmp_dir
  } do
    script = Path.join(tmp_dir, "idle.sh")
    File.write!(script, "#!/bin/sh\nsleep 5\n")
    File.chmod!(script, 0o755)

    start_supervised!(Supervisor.child_spec({V4L2, label: "right"}, id: :right))

    left =
      start_supervised!(
        Supervisor.child_spec(
          {V4L2, label: "left", executable: script, width: 2, height: 1, fps: 30},
          id: :left
        )
      )

    assert V4L2.live(V4L2.name_for("right")) == nil

    %{port: port} = :sys.get_state(left)
    send(left, {port, {:data, metadata_record(8_000.0, 2.0)}})
    send(left, {port, {:data, metadata_record(4_000.0, 4.0)}})

    for label <- ["left", "right"] do
      assert %{exposure_time_us: 4000, analogue_gain: 4.0, received_ms: received_ms} =
               V4L2.live(V4L2.name_for(label))

      assert_in_delta received_ms, System.system_time(:millisecond), 1_000
    end

    %{received_ms: before_ms} = V4L2.live(V4L2.name_for("left"))
    Process.sleep(20)
    send(left, {port, {:data, pair_record(5, 6)}})

    assert %{exposure_time_us: 4000, analogue_gain: 4.0, received_ms: after_ms} =
             V4L2.live(V4L2.name_for("right"))

    assert after_ms > before_ms
  end
end

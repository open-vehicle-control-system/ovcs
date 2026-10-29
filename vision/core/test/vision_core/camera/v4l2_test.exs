defmodule VisionCore.Camera.V4L2Test do
  use ExUnit.Case, async: false

  alias VisionCore.Camera.{Frame, V4L2}
  alias VisionCore.Timing

  @tmp Path.join(System.tmp_dir!(), "v4l2_test")

  defp pair_record(left_ns, right_ns) do
    <<4, 2::little-16, 1::little-16, left_ns::little-signed-64, right_ns::little-signed-64, 1, 2,
      3, 4>>
  end

  test "port arguments carry the size and every setting, defaults included" do
    args = V4L2.port_args(width: 768, height: 432, fps: 30, rotation: 180, analogue_gain: 2)

    assert Enum.take(args, 6) == ~w(--width 768 --height 432 --fps 30)
    settings = args |> Enum.drop(6) |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, v} end)
    assert settings["--rotation"] == "180"
    assert settings["--analogue-gain"] == "2.0"
    assert settings["--auto-exposure"] == "true"
    assert settings["--gamma"] == "2.2"
    assert map_size(settings) == length(V4L2.control_specs())
  end

  test "settings become name=value commands, checked against their specs" do
    assert V4L2.control_commands(rotation: 180, gamma: 1.8, auto_exposure: false) ==
             {:ok, ["rotation=180", "gamma=1.8", "auto_exposure=false"]}

    assert {:error, "rotation" <> _} = V4L2.control_commands(rotation: 90)
    assert {:error, "max_gain" <> _} = V4L2.control_commands(max_gain: 40)
    assert {:error, "unknown camera setting zoom"} = V4L2.control_commands(zoom: 2)
  end

  test "a setting changed on either side reaches the capture program" do
    File.mkdir_p!(@tmp)
    commands = Path.join(@tmp, "commands.bin")
    File.rm(commands)
    script = Path.join(@tmp, "listen.sh")
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

    Process.sleep(200)
    assert File.read!(commands) == <<9::32, "gamma=1.8">>
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

  test "the left camera runs the capture program and hands the right frame on, then stops with it" do
    File.mkdir_p!(@tmp)
    records = Path.join(@tmp, "records.bin")
    record = pair_record(5, 6)
    File.write!(records, <<byte_size(record)::32, record::binary>>)
    script = Path.join(@tmp, "capture.sh")
    File.write!(script, "#!/bin/sh\nsleep 0.3\ncat #{records}\n")
    File.chmod!(script, 0o755)

    start_supervised!(Supervisor.child_spec({V4L2, label: "right"}, id: :right))

    left =
      start_supervised!(
        Supervisor.child_spec(
          {V4L2, label: "left", executable: script, width: 2, height: 1, fps: 30},
          id: :left,
          restart: :temporary
        )
      )

    ref = Process.monitor(left)
    V4L2.register_listener(V4L2.name_for("left"), self())
    V4L2.register_listener(V4L2.name_for("right"), self())

    assert_receive {:"$gen_cast", {:camera_frame, %Frame{label: "left", grey: <<1, 2>>}}}, 2_000
    assert_receive {:"$gen_cast", {:camera_frame, %Frame{label: "right", grey: <<3, 4>>}}}, 2_000
    assert_receive {:DOWN, ^ref, :process, _, {:v4l2_capture_exit, 0}}, 2_000
  end
end

defmodule VisionCore.Camera.LibCameraTest do
  use ExUnit.Case, async: true

  alias VisionCore.Camera.{Frame, LibCamera}

  # The driver itself needs the native binary and two cameras; the
  # watchdog's decision is the part that can be wrong, and it is pure.
  @state %{
    started_at: 1_000,
    last_frame_at: nil,
    stall_timeout_ms: 2_000,
    startup_timeout_ms: 15_000
  }

  describe "stall_verdict/2" do
    test "waits for the first frame up to the startup timeout" do
      assert LibCamera.stall_verdict(@state, 1_000 + 15_000) == :ok
      assert LibCamera.stall_verdict(@state, 1_000 + 15_001) == {:no_first_frame, 15_001}
    end

    test "tolerates silence up to the stall timeout once frames have flowed" do
      flowing = %{@state | last_frame_at: 40_000}
      assert LibCamera.stall_verdict(flowing, 40_000 + 33) == :ok
      assert LibCamera.stall_verdict(flowing, 40_000 + 2_000) == :ok
      assert LibCamera.stall_verdict(flowing, 40_000 + 2_001) == {:stalled, 2_001}
    end

    test "the startup timeout no longer applies after the first frame" do
      # A camera that started long ago but delivered a frame just now is
      # fine however slow its start was.
      late_starter = %{@state | last_frame_at: 1_000 + 60_000}
      assert LibCamera.stall_verdict(late_starter, 1_000 + 60_500) == :ok
    end
  end

  describe "sync_route_commands/1" do
    test "none without sync" do
      assert LibCamera.sync_route_commands(nil) == []
    end

    test "routes the sync group over the loopback" do
      assert LibCamera.sync_route_commands(:client) == [
               ["link", "set", "lo", "multicast", "on"],
               ["route", "replace", "239.255.255.250/32", "dev", "lo"]
             ]
    end
  end

  describe "sync_args/1" do
    test "no role runs the camera free" do
      assert LibCamera.sync_args(nil) == []
    end

    test "a role is passed as server or client" do
      assert LibCamera.sync_args(:server) == ["--sync", "server"]
      assert LibCamera.sync_args(:client) == ["--sync", "client"]
    end
  end

  describe "exposure_mode_args/1" do
    test "no mode leaves libcamera's default" do
      assert LibCamera.exposure_mode_args(nil) == []
    end

    test "a mode is passed by name" do
      assert LibCamera.exposure_mode_args(:short) == ["--exposure-mode", "short"]
    end

    test "a mode is accepted as the string the controls and the export give" do
      assert LibCamera.exposure_mode_args("short") == ["--exposure-mode", "short"]
      assert_raise FunctionClauseError, fn -> LibCamera.exposure_mode_args("fastest") end
    end
  end

  describe "sensor_mode_args/1" do
    test "lets libcamera pick the mode by default" do
      assert LibCamera.sensor_mode_args(nil) == []
    end

    test "passes the mode's size" do
      assert LibCamera.sensor_mode_args({2304, 1296}) == ["--sensor-mode", "2304x1296"]
    end

    test "passes the mode's bit depth when given" do
      assert LibCamera.sensor_mode_args({2028, 1520, 12}) == ["--sensor-mode", "2028x1520:12"]
    end
  end

  describe "lens_position_args/1" do
    test "no position leaves the lens alone" do
      assert LibCamera.lens_position_args(nil) == []
    end

    test "a position is passed in dioptres, integers included" do
      assert LibCamera.lens_position_args(1.5) == ["--lens-position", "1.5"]
      assert LibCamera.lens_position_args(1) == ["--lens-position", "1.0"]
    end
  end

  describe "format_args/1" do
    test "JPEG frames are the capture program's default" do
      assert LibCamera.format_args(:jpeg) == []
    end

    test "grey frames are asked for by name" do
      assert LibCamera.format_args(:grey) == ["--format", "grey"]
    end
  end

  describe "grey frame records" do
    test "carry the frame's luma, row-major" do
      assert {:ok, %Frame{width: 3, height: 2, grey: <<1, 2, 3, 4, 5, 6>>, jpeg: nil}} =
               LibCamera.parse_record(
                 <<5, 3::little-16, 2::little-16, 0::little-signed-64, 1, 2, 3, 4, 5, 6>>
               )
    end

    test "are malformed unless they hold width * height bytes" do
      assert LibCamera.parse_record(<<5, 3::little-16, 2::little-16, 0::little-signed-64, 1>>) ==
               {:error, :malformed_record}
    end

    test "reach the listeners as grey frames under the camera's label" do
      packet = <<5, 2::little-16, 1::little-16, 0::little-signed-64, 7, 8>>

      state = %{
        label: "left",
        port: :port,
        listeners: [self()],
        start_controls: [],
        last_frame_at: nil
      }

      assert {:noreply, _state} = LibCamera.handle_info({:port, {:data, packet}}, state)

      assert_receive {:"$gen_cast",
                      {:camera_frame, %Frame{label: "left", width: 2, height: 1, grey: <<7, 8>>}}}
    end
  end

  describe "log records" do
    test "carry a level and the capture program's message" do
      assert LibCamera.parse_record(<<2, 1, "camera sync not established">>) ==
               {:log, :warning, "camera sync not established"}

      assert LibCamera.parse_record(<<2, 0, "focus fixed">>) == {:log, :info, "focus fixed"}

      assert LibCamera.parse_record(<<2, 2, "Camera::start failed">>) ==
               {:log, :error, "Camera::start failed"}
    end
  end

  describe "control_commands/1" do
    test "names libcamera's controls, enumerations by their values" do
      assert LibCamera.control_commands(exposure_mode: "short", lens_position: 1.5) ==
               {:ok, ["AeExposureMode=1", "AfMode=0", "LensPosition=1.5"]}

      assert LibCamera.control_commands(exposure_mode: :long, noise_reduction: "off") ==
               {:ok, ["AeExposureMode=2", "NoiseReductionMode=0"]}
    end

    test "hands exposure and gain back to the automatic mode at 0" do
      assert LibCamera.control_commands(exposure_time_us: 0, analogue_gain: 0) ==
               {:ok, ["ExposureTimeMode=0", "AnalogueGainMode=0"]}

      assert LibCamera.control_commands(exposure_time_us: 8000, analogue_gain: 2) ==
               {:ok,
                [
                  "ExposureTimeMode=1",
                  "ExposureTime=8000",
                  "AnalogueGainMode=1",
                  "AnalogueGain=2.0"
                ]}
    end

    test "refuses out-of-range values, unknown modes and unknown keys" do
      assert {:error, "brightness must be a number within" <> _} =
               LibCamera.control_commands(brightness: 2)

      assert {:error, "exposure_mode must be one of" <> _} =
               LibCamera.control_commands(exposure_mode: :fast)

      assert {:error, "exposure_time_us must be an integer" <> _} =
               LibCamera.control_commands(exposure_time_us: 10.5)

      assert {:error, "unknown camera control" <> _} = LibCamera.control_commands(sync: :server)
    end
  end

  describe "start_controls/1" do
    test "picks the control settings out of the camera opts" do
      assert LibCamera.start_controls(camera_id: 0, lens_position: 1.5, exposure_time_us: 8000) ==
               [lens_position: 1.5, exposure_time_us: 8000]

      assert LibCamera.start_controls(camera_id: 0, sync: :server) == []
    end
  end

  describe "start controls on the first frame" do
    test "are applied once, not on later frames" do
      port = Port.open({:spawn_executable, "/bin/cat"}, [:binary])
      packet = <<1, 2::little-16, 2::little-16, 0::little-signed-64, 1::little-32, 0>>

      state = %{
        label: "left",
        listeners: [],
        port: port,
        controls: %{},
        start_controls: [exposure_time_us: 8000],
        last_frame_at: nil
      }

      assert {:noreply, state} = LibCamera.handle_info({port, {:data, packet}}, state)
      assert state.start_controls == []
      assert state.controls == %{exposure_time_us: 8000}
      assert {:noreply, _state} = LibCamera.handle_info({port, {:data, packet}}, state)

      assert collect(port, "") == "ExposureTimeMode=1ExposureTime=8000"
      Port.close(port)
    end

    test "do not overwrite a control set before the first frame" do
      port = Port.open({:spawn_executable, "/bin/cat"}, [:binary])
      packet = <<1, 2::little-16, 2::little-16, 0::little-signed-64, 1::little-32, 0>>

      state = %{
        label: "left",
        listeners: [],
        port: port,
        controls: %{brightness: 0.2, contrast: 1.0},
        start_controls: [brightness: 0.2, contrast: 2.0],
        last_frame_at: nil
      }

      assert {:reply, {:ok, _controls}, state} =
               LibCamera.handle_call({:set_controls, [brightness: 0.5]}, nil, state)

      assert state.start_controls == [contrast: 2.0]
      assert {:noreply, state} = LibCamera.handle_info({port, {:data, packet}}, state)
      assert %{brightness: 0.5, contrast: 2.0} = state.controls
      Port.close(port)
    end

    defp collect(port, acc) do
      receive do
        {^port, {:data, data}} -> collect(port, acc <> data)
      after
        300 -> acc
      end
    end
  end

  describe "metadata records" do
    test "carry the values reported, the others absent" do
      values =
        for v <- [9_990.0, 2.5, 1.0, 1.2, 33_333.0, 4_100.0, 1.0, -12.0],
            into: <<>>,
            do: <<v::little-float-64>>

      # Everything reported but the digital gain (bit 2).
      present = 0b11111011

      assert {:metadata, live} =
               LibCamera.parse_record(<<3, present, 1_000::little-signed-64, values::binary>>)

      assert %{
               exposure_time_us: 9_990,
               analogue_gain: 2.5,
               lens_position: 1.2,
               frame_duration_us: 33_333,
               colour_temperature: 4_100,
               sync_ready: true,
               sync_timer_us: -12
             } = live

      refute Map.has_key?(live, :digital_gain)
    end
  end

  describe "controls before the first frame" do
    @describetag :tmp_dir

    test "are the composer's settings", %{tmp_dir: tmp_dir} do
      camera =
        start_camera(tmp_dir, "seeded",
          brightness: 0.2,
          exposure_time_us: 6000,
          exposure_mode: :short,
          lens_position: 1
        )

      assert %{
               brightness: 0.2,
               exposure_time_us: 6000,
               exposure_mode: "short",
               lens_position: 1.0,
               contrast: 1.0
             } = LibCamera.controls(camera)
    end

    test "take the exposure mode as the export renders it", %{tmp_dir: tmp_dir} do
      rows = [
        {[:components, :stereo, :left, :exposure_mode], "stereo.left.exposure_mode", "long"}
      ]

      "# In the options" <> _ = snippet = VisionCore.Parameters.Export.render(rows)
      [_header, options] = String.split(snippet, "\n", parts: 2)
      {[left: left], _binding} = Code.eval_string("[" <> options <> "]")

      camera = start_camera(tmp_dir, "string_mode", left)
      assert %{exposure_mode: "long"} = LibCamera.controls(camera)
    end

    @tag :capture_log
    test "leave out a setting the camera refuses", %{tmp_dir: tmp_dir} do
      camera = start_camera(tmp_dir, "refused", brightness: 5.0, contrast: 2)
      assert %{brightness: +0.0, contrast: 2.0} = LibCamera.controls(camera)
    end
  end

  describe "capture program arguments" do
    @describetag :tmp_dir

    test "ask for grey frames with format: :grey", %{tmp_dir: tmp_dir} do
      start_camera(tmp_dir, "grey", format: :grey)
      assert "--format grey" in captured_args(tmp_dir)
    end

    test "leave the format out by default", %{tmp_dir: tmp_dir} do
      start_camera(tmp_dir, "jpeg", [])
      refute Enum.any?(captured_args(tmp_dir), &String.starts_with?(&1, "--format"))
    end

    @tag :capture_log
    test "refuse an unknown format", %{tmp_dir: tmp_dir} do
      executable = fake_capture_program(tmp_dir)

      assert {:error, {{%ArgumentError{message: message}, _stacktrace}, _child}} =
               start_supervised(
                 {LibCamera, label: "rgb", camera_id: 0, executable: executable, format: :rgb}
               )

      assert message =~ ":format"
    end

    # Flag and value pairs, one per line, as the program received them.
    defp captured_args(tmp_dir) do
      path = Path.join(tmp_dir, "args")
      wait_until(fn -> File.exists?(path) and File.read!(path) =~ "\n" end)

      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.chunk_every(2)
      |> Enum.map(&Enum.join(&1, " "))
    end

    defp wait_until(check, attempts \\ 50) do
      cond do
        check.() -> :ok
        attempts == 0 -> flunk("timed out")
        true -> Process.sleep(10) && wait_until(check, attempts - 1)
      end
    end
  end

  # A driver on a capture program that records its arguments, reads its commands and sends nothing.
  defp start_camera(tmp_dir, label, opts) do
    executable = fake_capture_program(tmp_dir)

    start_supervised!(
      {LibCamera, [label: label, camera_id: 0, executable: executable] ++ opts},
      id: label
    )
  end

  defp fake_capture_program(tmp_dir) do
    executable = Path.join(tmp_dir, "camera_capture")

    File.write!(executable, """
    #!/bin/sh
    dir=$(dirname "$0")
    printf '%s\\n' "$@" > "$dir/args.tmp" && mv "$dir/args.tmp" "$dir/args"
    exec cat > /dev/null
    """)

    File.chmod!(executable, 0o755)
    executable
  end
end

defmodule RosBridge.Camera.LibCameraTest do
  use ExUnit.Case, async: true

  alias RosBridge.Camera.LibCamera

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
  end

  describe "sensor_mode_args/1" do
    test "lets libcamera pick the mode by default" do
      assert LibCamera.sensor_mode_args(nil) == []
    end

    test "passes the mode's size" do
      assert LibCamera.sensor_mode_args({2304, 1296}) == ["--sensor-mode", "2304x1296"]
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
end

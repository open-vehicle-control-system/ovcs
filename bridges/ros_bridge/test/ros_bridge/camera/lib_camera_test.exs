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

  describe "lens_position_args/1" do
    test "no position leaves the lens alone" do
      assert LibCamera.lens_position_args(nil) == []
    end

    test "a position is passed in dioptres, integers included" do
      assert LibCamera.lens_position_args(1.5) == ["--lens-position", "1.5"]
      assert LibCamera.lens_position_args(1) == ["--lens-position", "1.0"]
    end
  end
end

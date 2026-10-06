defmodule RosBridge.StereoCamera.TuningTest do
  use ExUnit.Case, async: true

  alias RosBridge.Camera.LibCamera
  alias RosBridge.StereoCamera.{OpenCV, Tuning}

  # The atoms the parser may resolve must exist, as they do once the
  # driver and the backend are loaded.
  setup_all do
    Code.ensure_loaded!(LibCamera)
    Code.ensure_loaded!(OpenCV)
    :ok
  end

  describe "parse/1" do
    test "reads assignments separated by spaces, semicolons and new lines" do
      assert Tuning.parse(
               "left.lens_position=1.2; stereo.uniqueness_ratio=20\nright.exposure_mode=short"
             ) ==
               {:ok,
                [
                  {:left, :lens_position, 1.2},
                  {:stereo, :uniqueness_ratio, 20},
                  {:right, :exposure_mode, :short}
                ]}
    end

    test "cameras means both" do
      assert Tuning.parse("cameras.exposure_mode=short") ==
               {:ok, [{:left, :exposure_mode, :short}, {:right, :exposure_mode, :short}]}
    end

    test "booleans" do
      assert Tuning.parse("stereo.clahe=false") == {:ok, [{:stereo, :clahe, false}]}
    end

    test "refuses unknown targets, malformed assignments, unknown names and empty text" do
      assert {:error, "unknown target" <> _} = Tuning.parse("middle.lens_position=1")
      assert {:error, "expected target.key=value" <> _} = Tuning.parse("left.lens_position")
      assert {:error, "unknown name" <> _} = Tuning.parse("left.no_such_control_zz=1")
      assert {:error, "no assignment" <> _} = Tuning.parse("  ")
    end
  end

  describe "LibCamera.control_commands/1" do
    test "turns accepted controls into the capture program's commands" do
      assert LibCamera.control_commands(exposure_mode: :short, lens_position: 1.5) ==
               {:ok, ["exposure_mode=short", "lens_position=1.5"]}
    end

    test "refuses out-of-range values, unknown modes and unknown keys" do
      assert {:error, "brightness must be within" <> _} =
               LibCamera.control_commands(brightness: 2)

      assert {:error, "exposure_mode must be one of" <> _} =
               LibCamera.control_commands(exposure_mode: :fast)

      assert {:error, "unknown camera control" <> _} = LibCamera.control_commands(sync: :server)
    end
  end

  describe "OpenCV.validate_options/1" do
    test "accepts the live matching settings" do
      assert OpenCV.validate_options(
               uniqueness_ratio: 20,
               num_disparities: 128,
               clahe_clip_limit: 3
             ) == :ok

      assert OpenCV.validate_options(row_offset: 28) == :ok
      assert OpenCV.validate_options(row_offset: -12.5) == :ok
    end

    test "refuses bad values and settings fixed at start" do
      assert {:error, "num_disparities must be a multiple of 16" <> _} =
               OpenCV.validate_options(num_disparities: 100)

      assert {:error, "uniqueness_ratio must be an integer" <> _} =
               OpenCV.validate_options(uniqueness_ratio: 20.5)

      assert {:error, "unknown or invalid stereo setting" <> _} =
               OpenCV.validate_options(block_size: 7)
    end
  end
end

defmodule RosBridge.StereoCamera.OpenCVTest do
  use ExUnit.Case, async: true

  alias Evision.StereoSGBM
  alias RosBridge.StereoCamera.OpenCV

  describe "create_matcher/1" do
    test "carries the smoothness penalties, 8 and 32 × block size² by default" do
      matcher = OpenCV.create_matcher(block_size: 9)
      assert StereoSGBM.getP1(matcher) == 648
      assert StereoSGBM.getP2(matcher) == 2592
    end

    test "takes explicit penalties" do
      matcher = OpenCV.create_matcher(block_size: 5, p1: 100, p2: 400)
      assert StereoSGBM.getP1(matcher) == 100
      assert StereoSGBM.getP2(matcher) == 400
    end
  end

  describe "OpenCV.validate_options/1" do
    test "accepts the live matching settings" do
      assert OpenCV.validate_options(
               uniqueness_ratio: 20,
               num_disparities: 128,
               clahe_clip_limit: 3
             ) == :ok
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

  describe "option_specs/0" do
    test "describes every setting validate_options/1 accepts" do
      for {key, spec} <- OpenCV.option_specs() do
        assert is_binary(spec.description), "#{key} has no description"
        assert spec.type in [:integer, :double, :bool]
      end

      assert {:num_disparities, %{type: :integer, range: {16, 256}}} =
               List.keyfind(OpenCV.option_specs(), :num_disparities, 0)
    end
  end
end

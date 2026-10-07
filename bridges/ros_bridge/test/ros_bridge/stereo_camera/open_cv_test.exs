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
end

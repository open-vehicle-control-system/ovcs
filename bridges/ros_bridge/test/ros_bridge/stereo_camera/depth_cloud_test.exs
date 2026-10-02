defmodule RosBridge.StereoCamera.DepthCloudTest do
  use ExUnit.Case, async: true

  alias RosBridge.StereoCamera.OpenCV

  test "depth and cloud share invalid pixels and metric distances on each frame" do
    for disparity <- [16, 32, 64] do
      raw =
        Evision.Mat.from_binary(
          <<-16::little-signed-16, disparity::little-signed-16, 0::little-signed-16,
            disparity::little-signed-16>>,
          {:s, 16},
          2,
          2,
          1
        )

      {_, depth, metres} = OpenCV.pack_disparity_and_depth(raw, 100.0, 0.1)
      <<0::little-16, d1::little-16, 0::little-16, d2::little-16>> = depth

      {cloud, count} =
        OpenCV.build_point_cloud(metres, %{
          cloud_decimation: 1,
          focal_length: 100.0,
          principal_point: {0.0, 0.0}
        })

      assert count == 2

      <<_x1::little-float-32, _y1::little-float-32, z1::little-float-32, _x2::little-float-32,
        _y2::little-float-32, z2::little-float-32>> = cloud

      assert_in_delta z1, d1 / 1000, 0.001
      assert_in_delta z2, d2 / 1000, 0.001
      assert_in_delta z1, 160.0 / disparity, 0.001
    end
  end
end

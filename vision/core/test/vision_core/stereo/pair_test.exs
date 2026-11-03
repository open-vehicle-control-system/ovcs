defmodule VisionCore.Stereo.PairTest do
  use ExUnit.Case, async: true

  alias VisionCore.Camera.Frame
  alias VisionCore.Stereo.Pair

  # A 64x48 pair matched over 16 disparities with a 9x7 Census window.
  defp pair do
    frame = %Frame{label: "left", width: 64, height: 48, capture_ns: 0, grey: <<>>}

    %Pair{
      left_frame: frame,
      right_frame: frame,
      geometry: %{width: 64, height: 48},
      disparity_range: %{min_disparity: 0, num_disparities: 16, block_size: 9, block_height: 7}
    }
  end

  test "the valid window leaves out the search range on the left and the Census window's rows" do
    assert Pair.valid_window(pair()) == {16, 3, 39, 42}
  end

  test "the disparity step is the 1/16 pixel stereo_msgs/DisparityImage consumers expect" do
    assert Pair.disparity_step(pair()) == 0.0625
  end
end

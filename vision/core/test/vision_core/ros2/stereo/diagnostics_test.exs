defmodule VisionCore.Ros2.Stereo.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias VisionCore.Camera.Frame
  alias VisionCore.Outputs
  alias VisionCore.Ros2.Stereo.Diagnostics

  @half_period_ns 16_666_666

  # Names the cameras, which need not be running: without live/1, nothing is asked of them.
  defmodule Camera do
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  test "measures the sync of the frames the cameras publish" do
    start_supervised!({Diagnostics, driver: Camera, topic_prefix: "stereo", fps: 30})

    for {label, capture_ns} <- [{"left", 1_000_000_000}, {"right", 1_000_200_000}] do
      frame = %Frame{label: label, width: 1, height: 1, capture_ns: capture_ns, grey: <<0>>}
      Outputs.publish({:camera_frame, Camera.name_for(label)}, {:camera_frame, frame})
    end

    assert %{pairs: 1, offset_median_ms: offset_ms} = Diagnostics.sync()
    assert_in_delta offset_ms, 0.2, 1.0e-9
  end

  describe "pair_offset/4" do
    test "measures right minus left against the nearest frame of the other camera" do
      assert Diagnostics.pair_offset(
               :right,
               1_000_200_000,
               [1_000_000_000, 966_666_666],
               @half_period_ns
             ) ==
               200_000

      assert Diagnostics.pair_offset(
               :left,
               1_000_200_000,
               [1_000_000_000, 966_666_666],
               @half_period_ns
             ) ==
               -200_000
    end

    test "pairs nothing farther than half a frame period, nor without frames" do
      assert Diagnostics.pair_offset(
               :right,
               1_020_000_000,
               [1_000_000_000],
               @half_period_ns
             ) == nil

      assert Diagnostics.pair_offset(:right, 1_000_000_000, [], @half_period_ns) == nil
    end
  end
end

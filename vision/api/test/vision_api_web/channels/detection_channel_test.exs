defmodule VisionApiWeb.DetectionChannelTest do
  use VisionApiWeb.ChannelCase, async: false

  alias VisionCore.Camera.Frame
  alias VisionCore.Detection.Live
  alias VisionCore.Stereo.Pair

  defp join do
    VisionApiWeb.DashboardSocket
    |> socket()
    |> subscribe_and_join(VisionApiWeb.DetectionChannel, "detections")
  end

  defp pair do
    frame = %Frame{label: "left", width: 480, height: 270, capture_ns: 0, grey: <<>>}

    %Pair{
      left_frame: frame,
      right_frame: frame,
      geometry: %{width: 480, height: 270, left_calibration: nil}
    }
  end

  test "pushes each detection result, with its objects' outlines on the left image" do
    start_supervised!({Live, max_hz: 1_000, outline_segments: 1})
    {:ok, _reply, _socket} = join()

    box = %{x0: 120.0, y0: 54.0, x1: 360.0, y1: 216.0}

    GenServer.cast(
      Live,
      {:detections, pair(), [%{label: "person", score: 0.6, z: 1.8, box: box}]}
    )

    assert_push "detections", %{detections: [detection]}
    assert %{label: "person", score: 0.6, distance_m: 1.8, outline: [[0.25, 0.2] | _]} = detection
  end

  test "joining without detection running is refused as unavailable" do
    assert {:error, %{reason: "unavailable"}} = join()
  end
end

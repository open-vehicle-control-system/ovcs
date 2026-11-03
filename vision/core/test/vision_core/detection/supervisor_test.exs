defmodule VisionCore.Detection.SupervisorTest do
  use ExUnit.Case, async: false

  alias VisionCore.Detection.Backend.Stub
  alias VisionCore.Detection.{Live, Supervisor}

  @moduletag :capture_log

  test "hands the backend, the pipeline and Live their options, and publishes on no ROS 2 topic" do
    unit =
      start_supervised!(
        {Supervisor,
         backend: Stub,
         boxes: [{0, 0.9, {0.0, 0.0, 0.5, 0.5}}],
         max_hz: 4,
         outline_segments: 2,
         min_score: 0.6,
         frame_id: "stereo_left_optical"}
      )

    assert %{interval_ms: 250} = :sys.get_state(Live)
    assert %{boxes: [{0, 0.9, _box}]} = :sys.get_state(Stub)

    assert %{min_score: 0.6, outline_segments: 2} =
             :sys.get_state(VisionCore.Detection.Pipeline)

    assert unit |> Elixir.Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
             Enum.sort([Stub, VisionCore.Detection.Pipeline, Live])
  end

  test "keeps every Hailo option to the backend" do
    assert Supervisor.split_backend_options(
             backend: VisionCore.Detection.Backend.Hailo,
             hef_path: "/models/m.hef",
             executable: "/bin/hailo_detect",
             outline_segments: 2
           ) ==
             {VisionCore.Detection.Backend.Hailo,
              [hef_path: "/models/m.hef", executable: "/bin/hailo_detect"]}
  end

  describe "the detection unit of a config" do
    defp config(components),
      do: %VisionCore.Config{components: components}

    test "its output: the detection pipeline's detections, whichever component starts it" do
      for detector <- [:detector, {:detector, boxes: []}, :hailo_detector, {:hailo_detector, []}] do
        assert Supervisor.outputs(config([detector])) ==
                 [detections: {:detections, VisionCore.Detection.Pipeline}]
      end
    end

    test "none without a component starting it" do
      assert Supervisor.outputs(config([{:stereo, []}])) == []
    end
  end
end

defmodule VisionCore.Detection.SupervisorTest do
  use ExUnit.Case, async: false

  alias VisionCore.Detection.Backend.Stub
  alias VisionCore.Detection.{Live, Supervisor}

  @moduletag :capture_log

  test "hands Live its options and the backend its own" do
    start_supervised!(
      {Supervisor,
       backend: Stub,
       boxes: [{0, 0.9, {0.0, 0.0, 0.5, 0.5}}],
       max_hz: 4,
       outline_segments: 2,
       min_score: 0.6}
    )

    assert %{interval_ms: 250, outline_segments: 2} = :sys.get_state(Live)
    assert %{boxes: [{0, 0.9, _box}]} = :sys.get_state(Stub)
    assert %{min_score: 0.6} = :sys.get_state(VisionCore.Detection.Pipeline)
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
end

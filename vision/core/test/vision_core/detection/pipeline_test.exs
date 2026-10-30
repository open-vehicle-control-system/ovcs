defmodule VisionCore.Detection.PipelineTest do
  use ExUnit.Case, async: true

  alias VisionCore.Detection.Pipeline

  test "the detection group lists its settings as build parameters" do
    state = %{detect_every_n: 2, min_score: 0.5, max_detections: 10, depth_sample_fraction: 0.25}

    assert %{id: "detection", name: "Detection", kind: :component, placement: :side} =
             group = Pipeline.group(state)

    assert group.position == 101

    assert Enum.map(group.parameters, &{&1.name, &1.type, &1.applies, &1.get.()}) == [
             {"detect_every_n", :integer, :build, 2},
             {"min_score", :double, :build, 0.5},
             {"max_detections", :integer, :build, 10},
             {"depth_sample_fraction", :double, :build, 0.25}
           ]
  end
end

defmodule VisionCore.Detection.PipelineTest do
  use ExUnit.Case, async: false

  alias VisionCore.Detection.Pipeline

  # Stands in for the stereo pipeline: tells the test who registers on it.
  defmodule StereoPipeline do
    use GenServer

    def start_link(test),
      do: GenServer.start_link(__MODULE__, test, name: VisionCore.Stereo.Pipeline)

    def init(test), do: {:ok, test}

    def handle_cast({:register_listener, listener}, test) do
      send(test, {:registered, listener})
      {:noreply, test}
    end
  end

  test "registers on the stereo pipeline again once it restarts, and waits for one that is not up yet" do
    detection = start_supervised!({Pipeline, backend: VisionCore.Detection.Backend.Stub})
    refute_receive {:registered, _}, 100

    start_supervised!({StereoPipeline, self()})
    assert_receive {:registered, ^detection}, 1_000

    stop_supervised!(StereoPipeline)
    start_supervised!({StereoPipeline, self()})
    assert_receive {:registered, ^detection}, 1_000
  end

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

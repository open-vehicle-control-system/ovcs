defmodule VisionCore.Detection.Backend.StubTest do
  use ExUnit.Case, async: false

  alias VisionCore.Detection.Backend.Stub

  @moduletag :capture_log

  test "declares an inference step that runs no model" do
    start_supervised!({VisionCore.Parameters, store: VisionCore.Parameters.MemoryStore})
    start_supervised!({Stub, []})

    assert %{
             pipeline: :detection,
             position: 102,
             compute: %{runs_on: :cpu, implementation: :elixir},
             parameters: []
           } = Enum.find(VisionCore.Parameters.groups(), &(&1.id == "detection.inference"))
  end

  test "reports no inference times" do
    start_supervised!({Stub, []})

    assert Stub.inference_times() == nil
  end

  test "a named pipeline's backend runs under its server name and declares that pipeline's step" do
    start_supervised!({VisionCore.Parameters, store: VisionCore.Parameters.MemoryStore})
    start_supervised!({Stub, name: Stub.Road, pipeline: :road})

    assert Stub.detect(Stub.Road, 3, Nx.iota({2, 4}, type: :u8)) == :ok
    assert_receive {:inference_detections, 3, [%{class_id: 0}]}
    assert Stub.available?(Stub.Road)
    refute Process.whereis(Stub)

    assert %{pipeline: :road, position: 102} =
             Enum.find(VisionCore.Parameters.groups(), &(&1.id == "road.inference"))
  end
end

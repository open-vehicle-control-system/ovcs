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
end

defmodule VisionCore.Ros2.Stereo.ParametersTest do
  use ExUnit.Case, async: false

  alias VisionCore.Preview
  alias VisionCore.Ros2.Stereo.Parameters

  # A pipeline with the stage settings it is given, none by default, and a camera driver without any.
  defmodule Pipeline do
    use GenServer
    def start_link(stages), do: GenServer.start_link(__MODULE__, stages, name: __MODULE__)
    def init(stages), do: {:ok, if(is_list(stages), do: stages, else: [])}
    def handle_call(:stage_options, _from, stages), do: {:reply, stages, stages}
  end

  defmodule Driver do
    def name_for(label), do: label
  end

  test "each live stage setting is a parameter named after its stage" do
    start_supervised!(
      {Pipeline,
       [
         %{
           stage: :match,
           specs: [
             p1: %{type: :integer, range: {0, 78}, applies: :live},
             paths: %{type: :integer, values: [3, 8], applies: :build}
           ],
           values: %{p1: 8, paths: 8}
         }
       ]}
    )

    start_supervised!(
      {Preview, config: %VisionCore.Config{zenoh_endpoint_ip: "127.0.0.1", components: []}}
    )

    names =
      Parameters.declarations(topic_prefix: "stereo", driver: Driver, pipeline: Pipeline)
      |> Enum.map(& &1.name)

    assert "stereo.match.p1" in names
    refute "stereo.match.paths" in names
  end

  test "the depth preview's settings are parameters that change it" do
    start_supervised!(Pipeline)

    start_supervised!(
      {Preview, config: %VisionCore.Config{zenoh_endpoint_ip: "127.0.0.1", components: []}}
    )

    declarations =
      Parameters.declarations(topic_prefix: "stereo", driver: Driver, pipeline: Pipeline)

    max_hz = Enum.find(declarations, &(&1.name == "stereo.preview.max_hz"))
    range = Enum.find(declarations, &(&1.name == "stereo.preview.depth_range_m"))

    assert %{type: :integer, value: 10} = max_hz
    assert %{type: :double, value: +0.0} = range
    assert :ok = range.set.(4.0)
    assert Preview.options().depth_range_m == 4.0
  end

  test "the row alignment correction is a switch, while it runs" do
    start_supervised!(Pipeline)

    start_supervised!(
      {Preview, config: %VisionCore.Config{zenoh_endpoint_ip: "127.0.0.1", components: []}}
    )

    names = fn ->
      Parameters.declarations(topic_prefix: "stereo", driver: Driver, pipeline: Pipeline)
    end

    refute Enum.any?(names.(), &(&1.name == "stereo.alignment_correction"))

    start_supervised!({VisionCore.Stereo.AlignmentCorrection, subscribe: false})
    switch = Enum.find(names.(), &(&1.name == "stereo.alignment_correction"))

    assert %{type: :bool, value: true} = switch
    assert :ok = switch.set.(false)
    refute VisionCore.Stereo.AlignmentCorrection.enabled?()
  end
end

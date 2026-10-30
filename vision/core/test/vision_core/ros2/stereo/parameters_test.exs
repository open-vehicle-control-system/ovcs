defmodule VisionCore.Ros2.Stereo.ParametersTest do
  use ExUnit.Case, async: false

  alias VisionCore.Preview
  alias VisionCore.Ros2.Stereo.Parameters

  # A pipeline with no runtime settings, and a camera driver without any.
  defmodule Pipeline do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
    def init(nil), do: {:ok, nil}
    def handle_call(:options, _from, state), do: {:reply, %{}, state}
    def handle_call(:option_specs, _from, state), do: {:reply, [], state}
  end

  defmodule Driver do
    def name_for(label), do: label
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

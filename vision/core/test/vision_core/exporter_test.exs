defmodule VisionCore.ExporterTest do
  use ExUnit.Case, async: true

  alias VisionCore.Exporter

  # Names a stereo unit's cameras, which need not be running.
  defmodule Camera do
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  # Reads the outputs its options name.
  defmodule Reading do
    def outputs(options), do: Keyword.fetch!(options, :outputs)
  end

  defmodule Acting do
    def actions(_options), do: [%{name: :ping, label: "Ping", description: "Answers at once."}]
  end

  defmodule RaisingActions do
    def actions(options), do: Keyword.fetch!(options, :actions)
  end

  defp config(components), do: %VisionCore.Config{components: components}

  test "the actions an exporter declares, none without actions/1 or when it raises" do
    assert Exporter.actions(Acting, []) == [
             %{name: :ping, label: "Ping", description: "Answers at once."}
           ]

    assert Exporter.actions(Reading, []) == []
    assert Exporter.actions(RaisingActions, []) == []
  end

  test "the outputs an exporter reads, each with the most values it takes a second, if bounded" do
    assert Exporter.output_specs(Reading,
             outputs: [{:camera_frame, :left}, stereo_pair: [max_hz: 5], detections: []]
           ) == {:ok, [{{:camera_frame, :left}, nil}, {:stereo_pair, 5}, {:detections, nil}]}
  end

  test "outputs naming no output, one twice, or an option other than a positive :max_hz are invalid" do
    for {outputs, entry} <- [
          {[:stereo_pairs], :stereo_pairs},
          {[{:camera_frame, :middle}], {:camera_frame, :middle}},
          {[stereo_pair: [rate: 5]], {:stereo_pair, [rate: 5]}},
          {[stereo_pair: [max_hz: 0]], {:stereo_pair, [max_hz: 0]}},
          {[:stereo_pair, stereo_pair: [max_hz: 5]], {:stereo_pair, [max_hz: 5]}}
        ] do
      assert Exporter.output_specs(Reading, outputs: outputs) ==
               {:error, {:invalid_output, entry}}
    end

    assert {:error, {:outputs_raised, _message}} = Exporter.output_specs(Reading, [])
  end

  test "an output resolves to the key its producer in the configuration publishes under" do
    config = config([{:stereo, driver: Camera, left: [], right: []}, :hailo_detector])

    assert Exporter.output_key(:stereo_pair, config) == {:stereo_pair, VisionCore.Stereo.Pipeline}

    assert Exporter.output_key({:camera_frame, :left}, config) ==
             {:camera_frame, Camera.name_for("left")}

    assert Exporter.output_key({:camera_frame, :right}, config) ==
             {:camera_frame, Camera.name_for("right")}

    assert Exporter.output_key(:detections, config) ==
             {:detections, VisionCore.Detection.Pipeline}
  end

  test "every detector component produces detections" do
    for detector <- [:detector, {:detector, boxes: []}, :hailo_detector, {:hailo_detector, []}] do
      assert Exporter.output_key(:detections, config([detector])) ==
               {:detections, VisionCore.Detection.Pipeline}
    end
  end

  test "an output no component of the configuration produces has no key" do
    for output <- [:stereo_pair, {:camera_frame, :left}, {:camera_frame, :right}, :detections] do
      assert Exporter.output_key(output, config([])) == nil
      assert Exporter.output_key(output, nil) == nil
    end
  end
end

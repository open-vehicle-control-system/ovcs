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
             outputs: [{:camera_frame, :left}, {:stereo_pair, max_hz: 5}, {:detections, :road}]
           ) ==
             {:ok,
              [{{:camera_frame, :left}, nil}, {:stereo_pair, 5}, {{:detections, :road}, nil}]}
  end

  test "a detection pipeline's detections are an output of their own, detection without a name" do
    assert Exporter.output_specs(Reading,
             outputs: [
               {:detections, :detection},
               {:detections, :road},
               {{:detections, :signs}, max_hz: 2}
             ]
           ) ==
             {:ok,
              [
                {{:detections, :detection}, nil},
                {{:detections, :road}, nil},
                {{:detections, :signs}, 2}
              ]}
  end

  test "a segmentation pipeline's results are an output of their own" do
    assert Exporter.output_specs(Reading,
             outputs: [{:segmentation, :road}, {{:segmentation, :lanes}, max_hz: 2}]
           ) == {:ok, [{{:segmentation, :road}, nil}, {{:segmentation, :lanes}, 2}]}
  end

  test "outputs naming no output, one twice, or an option other than a positive :max_hz are invalid" do
    for {outputs, entry} <- [
          {[:stereo_pairs], :stereo_pairs},
          {[{:camera_frame, :"front-cam"}], {:camera_frame, :"front-cam"}},
          {[{:camera_frame, "hq"}], {:camera_frame, "hq"}},
          {[{:camera_frame, :depth}], {:camera_frame, :depth}},
          {[stereo_pair: [rate: 5]], {:stereo_pair, [rate: 5]}},
          {[stereo_pair: [max_hz: 0]], {:stereo_pair, [max_hz: 0]}},
          {[:stereo_pair, stereo_pair: [max_hz: 5]], {:stereo_pair, [max_hz: 5]}},
          {[:detections], :detections},
          {[{:detections, :stereo}], {:detections, :stereo}},
          {[{:detections, :"front-cam"}], {:detections, :"front-cam"}},
          {[{:detections, "road"}], {:detections, "road"}},
          {[{:detections, :road}, {:detections, :road}], {:detections, :road}},
          {[{:segmentation, :stereo}], {:segmentation, :stereo}},
          {[{:segmentation, "road"}], {:segmentation, "road"}},
          {[:segmentation], :segmentation},
          {[{:segmentation, :road}, {:segmentation, :road}], {:segmentation, :road}}
        ] do
      assert Exporter.output_specs(Reading, outputs: outputs) ==
               {:error, {:invalid_output, entry}}
    end

    assert {:error, {:outputs_raised, _message}} = Exporter.output_specs(Reading, [])
  end

  test "a named camera's frames are an output of their own, beside the stereo pair's" do
    assert Exporter.output_specs(Reading,
             outputs: [{:camera_frame, :left}, {{:camera_frame, :hq}, max_hz: 2}]
           ) == {:ok, [{{:camera_frame, :left}, nil}, {{:camera_frame, :hq}, 2}]}
  end

  test "a named camera's frames resolve to the key its driver publishes under" do
    config =
      config([
        {:stereo, driver: Camera, left: [], right: []},
        {:camera, name: :hq, driver: Camera}
      ])

    assert Exporter.output_key({:camera_frame, :hq}, config) ==
             {:camera_frame, Camera.name_for("hq")}

    assert Exporter.output_key({:camera_frame, :left}, config) ==
             {:camera_frame, Camera.name_for("left")}

    assert Exporter.output_key({:camera_frame, :usb}, config) == nil
  end

  test "a camera's named output resolves to the key its driver publishes it under" do
    config =
      config([
        {:camera,
         name: :hq,
         driver: VisionCore.Camera.V4L2Single,
         outputs: [
           view: [resolution: {2028, 1520}, processor: :cpu],
           inference: [resolution: {1014, 760}, from: :view]
         ]}
      ])

    server = VisionCore.Camera.V4L2Single.name_for("hq")

    assert Exporter.output?({:camera_frame, :hq, :inference})
    refute Exporter.output?({:camera_frame, :left, :inference})
    assert Exporter.output_key({:camera_frame, :hq}, config) == {:camera_frame, server, :view}

    assert Exporter.output_key({:camera_frame, :hq, :inference}, config) ==
             {:camera_frame, server, :inference}

    assert Exporter.output_key({:camera_frame, :hq, :preview}, config) == nil
  end

  test "an output resolves to the key its producer in the configuration publishes under" do
    config = config([{:stereo, driver: Camera, left: [], right: []}, :hailo_detector])

    assert Exporter.output_key(:stereo_pair, config) == {:stereo_pair, VisionCore.Stereo.Pipeline}

    assert Exporter.output_key({:camera_frame, :left}, config) ==
             {:camera_frame, Camera.name_for("left")}

    assert Exporter.output_key({:camera_frame, :right}, config) ==
             {:camera_frame, Camera.name_for("right")}

    assert Exporter.output_key({:detections, :detection}, config) ==
             {:detections, :detection}
  end

  test "every detector component produces detections" do
    for detector <- [:detector, {:detector, boxes: []}, :hailo_detector, {:hailo_detector, []}] do
      assert Exporter.output_key({:detections, :detection}, config([detector])) ==
               {:detections, :detection}
    end
  end

  test "a pipeline's detections resolve to its own key" do
    config = config([{:detector, name: :road}, :detector, {:hailo_detector, name: :signs}])

    assert Exporter.output_key({:detections, :detection}, config) ==
             {:detections, :detection}

    assert Exporter.output_key({:detections, :road}, config) ==
             {:detections, :road}

    assert Exporter.output_key({:detections, :signs}, config) ==
             {:detections, :signs}

    assert Exporter.output_key({:detections, :lanes}, config) == nil

    assert Exporter.output_key({:detections, :detection}, config([{:detector, name: :road}])) ==
             nil
  end

  test "a segmentation pipeline's results resolve to its own key" do
    config =
      config([
        {:segmenter, name: :road, source: {:camera, :hq}},
        {:qnn_segmenter, name: :lanes, source: {:camera, :hq}}
      ])

    assert Exporter.output_key({:segmentation, :road}, config) ==
             {:segmentation, :road}

    assert Exporter.output_key({:segmentation, :lanes}, config) ==
             {:segmentation, :lanes}

    assert Exporter.output_key({:segmentation, :signs}, config) == nil
  end

  test "an output no component of the configuration produces has no key" do
    for output <- [
          :stereo_pair,
          {:camera_frame, :left},
          {:camera_frame, :right},
          {:camera_frame, :hq},
          {:detections, :detection},
          {:detections, :road},
          {:segmentation, :road}
        ] do
      assert Exporter.output_key(output, config([])) == nil
      assert Exporter.output_key(output, nil) == nil
    end
  end
end

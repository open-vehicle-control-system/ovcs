defmodule VisionCore.Ros2.BagExporter.PresetTest do
  # Starts the Zenoh exporter's state, which subscribes to calibration keys.
  use ExUnit.Case, async: false

  alias VisionCore.BagTestUnit
  alias VisionCore.Ros2.BagExporter.Preset
  alias VisionCore.Ros2.ZenohExporter

  @moduletag :capture_log

  defp publish_to(test) do
    fn topic, module, _message, _options ->
      send(test, {:published, topic, module})
      :ok
    end
  end

  # The topics and modules the Zenoh exporter publishes with `preset`'s options, handed a value of each output.
  defp published(preset, config) do
    options =
      Keyword.delete(Preset.options(preset, config), :max_hz) ++
        [config: config, link: false, services: false, publish: publish_to(self())]

    {:ok, state} = ZenohExporter.init(options)
    outputs = ZenohExporter.outputs(options)

    state =
      for {output, value} <- BagTestUnit.values(1_000), output in outputs, reduce: state do
        state ->
          {:ok, state} = ZenohExporter.handle_output(output, value, state)
          state
      end

    {:ok, _state} = ZenohExporter.handle_info(:publish_transforms, state)
    collect([])
  end

  defp collect(published) do
    receive do
      {:published, topic, module} -> collect([{topic, module} | published])
    after
      0 -> published |> Enum.reverse() |> Enum.uniq()
    end
  end

  defp topics(published), do: published |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

  @tag :tmp_dir
  test "replay: raw stereo and its camera info, each camera's JPEG and info, transforms",
       %{tmp_dir: tmp_dir} do
    config = BagTestUnit.config(pose: pose_file(tmp_dir))

    assert Preset.options(:replay, config) == [
             stereo: [raw_images: true, publish_raw_images: false, pair_messages: []],
             cameras: [outputs: [hq: :view_jpeg]]
           ]

    assert topics(published(:replay, config)) == [
             "/tf_static",
             "hq/camera_info",
             "hq/image_raw/compressed",
             "stereo/left/camera_info",
             "stereo/left/image_raw",
             "stereo/right/camera_info",
             "stereo/right/image_raw"
           ]
  end

  @tag :tmp_dir
  test "review: the left image compressed, each camera, the depth, every pipeline, transforms",
       %{tmp_dir: tmp_dir} do
    config = BagTestUnit.config(pose: pose_file(tmp_dir))

    assert Preset.options(:review, config) == [
             stereo: [sides: [:left], pair_messages: [:depth]],
             cameras: [camera_info_interval_frames: 10, outputs: [hq: :view_jpeg]],
             detections: [pipelines: [:objects]],
             segmentation: [],
             max_hz: [pairs: 5, cameras: 10]
           ]

    topics = topics(published(:review, config))

    assert "stereo/left/image_raw/compressed" in topics
    assert "stereo/depth/image_rect" in topics and "stereo/depth/camera_info" in topics
    assert "hq/image_raw/compressed" in topics and "/tf_static" in topics
    assert Enum.any?(topics, &String.starts_with?(&1, "objects/"))
    assert Enum.any?(topics, &String.starts_with?(&1, "road/"))

    for topic <- ["stereo/left/image_raw", "stereo/disparity", "stereo/points"],
        do: refute(topic in topics)

    refute Enum.any?(topics, &String.starts_with?(&1, "stereo/right/"))
  end

  test "names only what the configuration has" do
    assert Preset.options(:replay, %VisionCore.Config{}) == []
    assert Preset.options(:review, %VisionCore.Config{}) == [max_hz: [pairs: 5, cameras: 10]]

    stereo_only = %{
      BagTestUnit.config()
      | components: Enum.take(BagTestUnit.config().components, 1)
    }

    assert Preset.options(:review, stereo_only) == [
             stereo: [sides: [:left], pair_messages: [:depth]],
             max_hz: [pairs: 5, cameras: 10]
           ]
  end

  test "takes a camera's default output when it has no JPEG one" do
    config =
      Map.update!(BagTestUnit.config(), :components, fn components ->
        Enum.map(components, fn
          {:camera, opts} ->
            {:camera, Keyword.update!(opts, :outputs, &Keyword.delete(&1, :view_jpeg))}

          component ->
            component
        end)
      end)

    assert Preset.options(:replay, config)[:cameras] == []
    assert Preset.options(:review, config)[:cameras] == [camera_info_interval_frames: 10]
  end

  # Review Focus 3: a type without its definition would fail at the first recording.
  @tag :tmp_dir
  test "every message module the presets publish has its ROS 2 definition", %{tmp_dir: tmp_dir} do
    config = BagTestUnit.config(pose: pose_file(tmp_dir))

    modules =
      for preset <- Preset.names(),
          {_topic, module} <- published(preset, config),
          uniq: true,
          do: module

    assert length(modules) > 5

    for module <- modules do
      Code.ensure_loaded!(module)

      assert function_exported?(module, :msg_definition, 0),
             "#{inspect(module)} has no definition"

      assert is_binary(Ros2Zenoh.definition(module))
    end
  end

  defp pose_file(dir) do
    path = Path.join(dir, "hq_pose.yaml")
    File.write!(path, "rotation: [1, 0, 0, 0, 1, 0, 0, 0, 1]\ntranslation: [-0.1, 0, 0]\n")
    path
  end
end

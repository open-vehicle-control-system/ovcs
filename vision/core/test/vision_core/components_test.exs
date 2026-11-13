defmodule VisionCore.ComponentsTest do
  use ExUnit.Case, async: true

  alias VisionCore.Components

  # A unit that gives up exits :shutdown; restarting it would spend the vision core's own budget.
  test "the stereo, detection and camera units are not restarted once they give up" do
    for component <- [:detector, :stereo] do
      assert [%{restart: :transient}] = Components.start(component, [])
    end

    assert [%{restart: :transient}] =
             Components.start(:camera, name: :hq, driver: VisionCore.Camera.GStreamer)
  end

  # The vision core's supervisor refuses two children with one id.
  test "each detector's unit is a child of its own, identified by its pipeline's name" do
    for {component, opts, id} <- [
          {:detector, [],
           VisionCore.Pipelines.server(VisionCore.Detection.Supervisor, :detection)},
          {:detector, [name: :road],
           VisionCore.Pipelines.server(VisionCore.Detection.Supervisor, :road)},
          {:qnn_detector, [name: :signs],
           VisionCore.Pipelines.server(VisionCore.Detection.Supervisor, :signs)},
          {:hailo_detector, [],
           VisionCore.Pipelines.server(VisionCore.Detection.Supervisor, :detection)}
        ] do
      assert [%{id: ^id}] = Components.start(component, opts)
    end
  end

  test "each segmenter's unit is a child of its own, identified by its pipeline's name, not restarted once it gives up" do
    for {component, opts, id} <- [
          {:segmenter, [name: :road, source: {:camera, :hq}],
           VisionCore.Pipelines.server(VisionCore.Segmentation.Supervisor, :road)},
          {:qnn_segmenter, [name: :lane, source: {:camera, :hq}],
           VisionCore.Pipelines.server(VisionCore.Segmentation.Supervisor, :lane)}
        ] do
      assert [%{id: ^id, restart: :transient, type: :supervisor}] =
               Components.start(component, opts)
    end
  end

  test ":qnn_segmenter runs on the QNN backend" do
    assert [%{start: {VisionCore.Segmentation.Supervisor, :start_link, [opts]}}] =
             Components.start(:qnn_segmenter, name: :road)

    assert opts[:backend] == VisionCore.Segmentation.Backend.Qnn
  end

  test "a segmenter without a valid name is refused, saying so" do
    for {opts, message} <- [
          {[], "a segmenter needs a :name"},
          {[name: :stereo], "a segmentation pipeline's name is an atom"}
        ] do
      error = assert_raise ArgumentError, fn -> Components.start(:segmenter, opts) end
      assert error.message =~ message
    end
  end

  test "a camera is a unit of its own, identified by its name" do
    assert [%{id: {:camera, :hq}, restart: :transient, type: :supervisor}] =
             Components.start(:camera, name: :hq, driver: VisionCore.Camera.V4L2Single, csiphy: 2)
  end

  test "a camera without a valid name or a driver is refused, saying so" do
    for {opts, message} <- [
          {[driver: VisionCore.Camera.GStreamer], "a :camera component needs a :name"},
          {[name: "hq", driver: VisionCore.Camera.GStreamer], "got \"hq\""},
          {[name: :left, driver: VisionCore.Camera.GStreamer], "got :left"},
          {[name: :hq], "a :camera component needs a :driver"},
          {[name: :hq, driver: VisionCore.Camera.V4L2Singel], "is not a VisionCore.Camera"},
          {[name: :hq, driver: "gstreamer"], "is not a VisionCore.Camera"}
        ] do
      error = assert_raise ArgumentError, fn -> Components.start(:camera, opts) end
      assert error.message =~ message
    end
  end

  test "the heartbeat and the simulator clock are not components: the ROS 2 exporter and the ros2: section own them" do
    for component <- [:heartbeat, :simulator_clock] do
      assert_raise FunctionClauseError, fn -> Components.start(component, []) end
    end
  end
end

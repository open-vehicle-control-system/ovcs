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

  test "a camera may be named left or right, the stereo unit's cameras being labelled under its prefix" do
    for name <- [:left, :right] do
      assert [%{id: {:camera, ^name}}] =
               Components.start(:camera, name: name, driver: VisionCore.Camera.GStreamer)
    end
  end

  test "a camera without a valid name or a driver is refused, saying so" do
    for {opts, message} <- [
          {[driver: VisionCore.Camera.GStreamer], "a :camera component needs a :name"},
          {[name: "hq", driver: VisionCore.Camera.GStreamer], "got \"hq\""},
          {[name: :depth, driver: VisionCore.Camera.GStreamer], "got :depth"},
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

  describe "wire_streams!/1" do
    @outputs [
      half: [resolution: {1152, 648}, processor: :isp, send: false],
      half_jpeg: [from: :half, format: :jpeg, quality: 80]
    ]

    @stereo_options [
      driver: VisionCore.Camera.LibCamera,
      left: [camera_id: 1, sensor_mode: {2304, 1296}, format: :grey],
      right: [camera_id: 0, sensor_mode: {2304, 1296}, format: :grey]
    ]
    @stream_options [
      name: :left,
      driver: VisionCore.Camera.LibCameraStream,
      stream_of: :left,
      max_hz: 10,
      outputs: @outputs
    ]
    @stereo {:stereo, @stereo_options}
    @stream {:camera, @stream_options}

    defp stereo(options), do: {:stereo, @stereo_options ++ options}

    defp side(components, side) do
      {:stereo, opts} = List.keyfind(components, :stereo, 0)
      Keyword.fetch!(opts, side)
    end

    defp camera(components, name) do
      Enum.find_value(components, fn
        {:camera, opts} -> if opts[:name] == name, do: opts
        _other -> nil
      end)
    end

    test "gives the stereo side the camera's outputs and max_hz, and the camera the side's label" do
      components = Components.wire_streams!([@stereo, @stream])

      assert side(components, :left) ==
               [camera_id: 1, sensor_mode: {2304, 1296}, format: :grey] ++
                 [outputs: @outputs, outputs_max_hz: 10]

      assert side(components, :right) == [camera_id: 0, sensor_mode: {2304, 1296}, format: :grey]
      assert camera(components, :left)[:side_label] == "stereo/left"
    end

    test "names the side under the stereo unit's prefix, and leaves out a max_hz not given" do
      components =
        Components.wire_streams!([
          stereo(prefix: "front"),
          {:camera,
           name: :colour,
           driver: VisionCore.Camera.LibCameraStream,
           stream_of: :right,
           outputs: @outputs}
        ])

      assert camera(components, :colour)[:side_label] == "front/right"
      refute Keyword.has_key?(side(components, :right), :outputs_max_hz)
      assert side(components, :right)[:outputs] == @outputs
    end

    test "leaves a configuration without a stream as it is" do
      components = [
        @stereo,
        {:camera, name: :hq, driver: VisionCore.Camera.GStreamer, device: "/dev/video0"}
      ]

      assert Components.wire_streams!(components) == components
      assert Components.wire_streams!([]) == []
    end

    for {refusal, components, message} <- [
          {"a stream without a stereo unit", [@stream],
           "camera :left: stream_of: :left names a side of the stereo unit, " <>
             "and there is no :stereo component"},
          {"a stereo unit whose driver is not LibCamera",
           [
             {:stereo, driver: VisionCore.Camera.V4L2Pair, left: [csiphy: 0], right: [csiphy: 1]},
             @stream
           ],
           "camera :left: stream_of: is a second stream of a VisionCore.Camera.LibCamera " <>
             "capture, and the stereo unit's driver is VisionCore.Camera.V4L2Pair"},
          {"a stereo unit on GStreamer",
           [{:stereo, driver: VisionCore.Camera.GStreamer, left: [], right: []}, @stream],
           "the stereo unit's driver is VisionCore.Camera.GStreamer"},
          {"a stereo unit on ROS 2 topics",
           [{:stereo, driver: VisionCore.Ros2.Camera, left: [], right: []}, @stream],
           "the stereo unit's driver is VisionCore.Ros2.Camera"},
          {"a side named twice",
           [@stereo, @stream, {:camera, Keyword.put(@stream_options, :name, :colour)}],
           "cameras :left and :colour both name stream_of: :left: " <>
             "the ISP makes one stream beside the frames' own"},
          {"a side that is neither left nor right",
           [@stereo, {:camera, Keyword.put(@stream_options, :stream_of, :middle)}],
           "camera :left: stream_of: is :left or :right, the stereo side whose capture makes it, " <>
             "got :middle"},
          {"stream_of: on another driver",
           [
             @stereo,
             {:camera, name: :hq, driver: VisionCore.Camera.GStreamer, stream_of: :left}
           ],
           "camera :hq: stream_of: is VisionCore.Camera.LibCameraStream's, " <>
             "and its driver is VisionCore.Camera.GStreamer"},
          {"a LibCameraStream camera without stream_of:",
           [@stereo, {:camera, name: :left, driver: VisionCore.Camera.LibCameraStream}],
           "camera :left: VisionCore.Camera.LibCameraStream needs stream_of:, " <>
             "the stereo side whose capture makes it"},
          {"a camera without outputs",
           [
             @stereo,
             {:camera, name: :left, driver: VisionCore.Camera.LibCameraStream, stream_of: :left}
           ], "camera :left: it names its :outputs, which the stereo side's capture makes"},
          {"an ISP output larger than the side's sensor mode",
           [
             @stereo,
             {:camera,
              Keyword.put(@stream_options, :outputs,
                full: [resolution: {4608, 2592}, processor: :isp, send: false],
                full_jpeg: [from: :full, format: :jpeg]
              )}
           ],
           "camera :left, made by the stereo unit's left camera as its :outputs and " <>
             ":outputs_max_hz (the camera's max_hz): output full: 4608x2592 is larger than " <>
             "the sensor mode's 2304x1296, the most the ISP makes"},
          {"an ISP output of an odd size",
           [
             @stereo,
             {:camera,
              Keyword.put(@stream_options, :outputs,
                half: [resolution: {1152, 649}, processor: :isp, send: false],
                half_jpeg: [from: :half, format: :jpeg]
              )}
           ], "output half: an ISP output takes an even width and height, not 1152x649"},
          {"a max_hz out of range",
           [@stereo, {:camera, Keyword.put(@stream_options, :max_hz, 0)}],
           ":outputs_max_hz is a number above 0 and up to 1000, got 0"}
        ] do
      @components components
      @message message

      test "refuses #{refusal}" do
        error = assert_raise ArgumentError, fn -> Components.wire_streams!(@components) end
        assert error.message =~ @message
      end
    end
  end

  describe "hailo_children/1" do
    test "none without a Hailo unit" do
      assert Components.hailo_children([:stereo, {:qnn_detector, dlc_path: "/m.dlc"}]) == []
    end

    test "one VisionCore.Hailo for every Hailo unit, each its pipeline's network, in order" do
      assert [
               %{
                 id: VisionCore.Hailo.Supervisor,
                 restart: :transient,
                 start: {VisionCore.Hailo.Supervisor, :start_link, [opts]}
               }
             ] =
               Components.hailo_children([
                 {:hailo_segmenter,
                  name: :road, source: {:camera, :left, :half_jpeg}, hef_path: "/stdc1.hef"},
                 :stereo,
                 {:hailo_detector, hef_path: "/objects.hef", score_threshold: 0.5},
                 {:hailo_detector, name: :signs, hef_path: "/signs.hef", executable: "/bin/hailo"}
               ])

      assert opts[:networks] == [
               road: [kind: :segmentation, classes: 19, hef_path: "/stdc1.hef"],
               detection: [kind: :detection, hef_path: "/objects.hef", score_threshold: 0.5],
               signs: [kind: :detection, hef_path: "/signs.hef"]
             ]

      assert opts[:executable] == "/bin/hailo"
    end
  end
end

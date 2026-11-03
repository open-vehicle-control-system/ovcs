defmodule VisionCore.Ros2.ExporterTest do
  # Publishes pairs under the stereo pipeline's key, which other tests subscribe to.
  use ExUnit.Case, async: false

  alias Ros2Zenoh.BuiltinInterfaces.Msg.Time
  alias Ros2Zenoh.FoxgloveMsgs.Msg.ImageAnnotations
  alias Ros2Zenoh.SensorMsgs.Msg.{CameraInfo, CompressedImage, Image}
  alias Ros2Zenoh.StdMsgs.Msg.Header
  alias Ros2Zenoh.StdMsgs.Msg.String, as: StringMessage
  alias Ros2Zenoh.StereoMsgs.Msg.DisparityImage
  alias Ros2Zenoh.VisualizationMsgs.Msg.{Marker, MarkerArray}
  alias VisionCore.Camera.Frame
  alias VisionCore.Exporter.Runner
  alias VisionCore.Outputs
  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Ros2.Exporter
  alias VisionCore.Ros2.Exporter.Diagnostics
  alias VisionCore.Ros2.Services.SetCameraInfoServer
  alias VisionCore.Ros2.ZenohClient
  alias VisionCore.Stereo.Pair

  @moduletag :capture_log
  @calibration Path.expand("../../support/calibration", __DIR__)

  # Names the cameras, which need not be running.
  defmodule Camera do
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  # Names a second unit's cameras, for the tests that publish through the runner.
  defmodule OtherCamera do
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  defp publish_to(test) do
    fn topic, _module, message, _options ->
      send(test, {:published, topic, message})
      :ok
    end
  end

  defp register_to(test) do
    fn service_name, _module, _handler ->
      send(test, {:registered, service_name})
      :ok
    end
  end

  # A configuration with the ROS 2 link and a stereo unit of `driver`'s cameras.
  defp config(driver, stereo \\ []) do
    %VisionCore.Config{
      ros2: [zenoh_endpoint_ip: "127.0.0.1"],
      components: [
        {:stereo,
         Keyword.merge(
           [
             driver: driver,
             width: 64,
             height: 48,
             left: [sync: :server, calibration_path: Path.join(@calibration, "stereo_left.yaml")],
             right: [calibration_path: Path.join(@calibration, "stereo_right.yaml")]
           ],
           stereo
         )}
      ]
    }
  end

  defp options(driver, options),
    do:
      [config: config(driver), publish: publish_to(self()), register_service: register_to(self())] ++
        options

  defp pair(frame_id \\ "stereo_left_optical") do
    frame = %Frame{
      label: "left",
      frame_id: frame_id,
      width: 8,
      height: 4,
      capture_ns: 0,
      grey: <<>>
    }

    %Pair{
      left_frame: frame,
      right_frame: %{frame | label: "right", frame_id: "stereo_right_optical"},
      left: Nx.broadcast(Nx.u8(0), {4, 8}),
      geometry: %{
        focal_length_px: 600.0,
        baseline_m: 0.08,
        left_calibration: CameraCalibration.load!(Path.join(@calibration, "stereo_left.yaml"))
      },
      disparity_range: %{min_disparity: 0, num_disparities: 2, block_size: 1},
      disparity_scale: 16,
      disparity_bytes: :binary.copy(<<0::32>>, 32),
      depth: :binary.copy(<<0::16>>, 32),
      cloud: :binary.copy(<<0::32>>, 3 * 2),
      cloud_points: 2,
      cloud_size: {1, 2}
    }
  end

  defp detection(label) do
    %{
      label: label,
      score: 0.8,
      x: 0.1,
      y: 0.2,
      z: 2.0,
      width: 0.5,
      height: 1.0,
      depth: 0.1,
      outline: [{0.0, 0.0}, {20.0, 0.0}, {20.0, 20.0}, {0.0, 20.0}],
      caption: "#{label} 0.80 2.00m"
    }
  end

  defp jpeg_frame(label, capture_ns),
    do: %Frame{
      label: label,
      frame_id: "#{label}_optical",
      width: 2,
      height: 2,
      capture_ns: capture_ns,
      jpeg: <<0xFF, 0xD8>>
    }

  # Started, and done with the exporter's init/1, so subscribed.
  defp start_runner(options, config) do
    runner = start_supervised!({Runner, exporter: Exporter, options: options, config: config})
    :sys.get_state(runner)
    runner
  end

  describe "check/1" do
    test "runs with the ROS 2 link, whatever it publishes" do
      assert Exporter.check(options(Camera, stereo: [], detections: [], heartbeat: [])) == :ok

      assert Exporter.check(
               heartbeat: [],
               config: %VisionCore.Config{ros2: [zenoh_endpoint_ip: "127.0.0.1"]}
             ) == :ok
    end

    test "refuses to run without the ROS 2 link" do
      assert {:error, reason} = Exporter.check(heartbeat: [], config: %VisionCore.Config{})
      assert reason =~ "no ros2: section"
    end

    test "refuses to publish a stereo unit the configuration has none of, or one it cannot read" do
      no_unit = %VisionCore.Config{ros2: [zenoh_endpoint_ip: "127.0.0.1"]}
      assert {:error, reason} = Exporter.check(stereo: [], config: no_unit)
      assert reason =~ "no :stereo component"

      assert {:error, reason} = Exporter.check(stereo: [], config: config(nil))
      assert reason =~ ":driver"

      assert {:error, reason} = Exporter.check(stereo: [], config: config(Camera, left: :front))
      assert reason =~ ":left"
    end
  end

  test "is listed as ROS 2" do
    assert Exporter.describe([]) == %{id: :ros2, name: "ROS 2"}
  end

  describe "outputs/1" do
    test "reads the stereo unit's pairs and frames, and the detections, each when it publishes them" do
      assert Exporter.outputs(stereo: [], detections: []) == [
               :stereo_pair,
               {:camera_frame, :left},
               {:camera_frame, :right},
               :detections
             ]

      assert Exporter.outputs(heartbeat: []) == []
    end
  end

  describe "children/1" do
    test "measures the cameras' sync in a helper, which publishes as the exporter does" do
      publish = publish_to(self())

      assert [{Diagnostics, diagnostics} | _set_camera_info] =
               Exporter.children(stereo: [], config: config(Camera), publish: publish)

      assert diagnostics[:driver] == Camera
      assert diagnostics[:fps] == 30
      assert diagnostics[:left][:sync] == :server
      assert diagnostics[:topic_prefix] == "stereo"
      assert diagnostics[:publish] == publish
    end

    @tag :tmp_dir
    test "answers set_camera_info for each side, writing the calibration to the store when there is one",
         %{tmp_dir: tmp_dir} do
      config = config(Camera, calibration_store_dir: tmp_dir)

      assert [_diagnostics, left, right] =
               Exporter.children(stereo: [topic_prefix: "front"], config: config)

      assert %{
               id: {SetCameraInfoServer, :left},
               start: {SetCameraInfoServer, :start_link, [left_options]}
             } = left

      assert left_options[:service_name] == "front/left/set_camera_info"
      assert left_options[:calibration_path] == Path.join(tmp_dir, "stereo_left.yaml")
      assert left_options[:camera_name] == "stereo_left"

      assert left_options[:reload] ==
               {VisionCore.Stereo.Supervisor, :reload_stored_calibration,
                [
                  VisionCore.Stereo.Pipeline,
                  "stereo",
                  Path.join(tmp_dir, "stereo_left.yaml"),
                  Path.join(tmp_dir, "stereo_right.yaml")
                ]}

      assert %{start: {SetCameraInfoServer, :start_link, [right_options]}} = right
      assert right_options[:service_name] == "front/right/set_camera_info"
    end

    test "without a store, set_camera_info writes the calibration file the stereo unit reads" do
      assert [_diagnostics, left, _right] = Exporter.children(stereo: [], config: config(Camera))
      %{start: {SetCameraInfoServer, :start_link, [left_options]}} = left

      assert left_options[:calibration_path] == Path.join(@calibration, "stereo_left.yaml")

      assert left_options[:reload] ==
               {VisionCore.Stereo.Supervisor, :reload_calibration,
                [VisionCore.Stereo.Pipeline, "stereo"]}
    end

    test "no helper without a stereo unit to publish" do
      assert Exporter.children(heartbeat: [], config: config(Camera)) == []
    end
  end

  test "is connected while the ROS 2 link has a session, disconnected otherwise" do
    {:ok, state} = Exporter.init(options(Camera, heartbeat: []))
    assert Exporter.status(state) == {:warning, "Disconnected"}

    session = local_session()

    start_supervised!(
      {ZenohClient, endpoint_ip: "127.0.0.1", open_session: fn _endpoint -> {:ok, session} end}
    )

    assert eventually(fn -> ZenohClient.link().connected end)
    assert Exporter.status(state) == {:ok, "Connected"}
  end

  # A Zenoh session that needs no router.
  defp local_session do
    config =
      Zenohex.Config.default()
      |> Zenohex.Config.update_in(["mode"], fn _ -> "peer" end)
      |> Zenohex.Config.update_in(["scouting", "multicast", "enabled"], fn _ -> false end)
      |> Zenohex.Config.update_in(["listen", "endpoints"], fn _ -> [] end)

    {:ok, session} = Zenohex.Session.open(config)
    on_exit(fn -> Zenohex.Session.close(session) end)
    session
  end

  describe "heartbeat" do
    test "names the node and counts, every interval" do
      {:ok, state} =
        Exporter.init(
          heartbeat: [interval_ms: 10],
          node_name: "front_vision",
          publish: publish_to(self())
        )

      assert_receive :heartbeat, 1_000
      {:ok, state} = Exporter.handle_info(:heartbeat, state)
      assert_receive {:published, "ovcs_heartbeat", %StringMessage{data: first}}
      assert first =~ ~r/^front_vision heartbeat 1 @ \d+$/

      assert_receive :heartbeat, 1_000
      {:ok, _state} = Exporter.handle_info(:heartbeat, state)
      assert_receive {:published, "ovcs_heartbeat", %StringMessage{data: second}}
      assert second =~ "heartbeat 2 @"
    end

    test "names the node of the ros2: section by default" do
      config = %VisionCore.Config{
        ros2: [zenoh_endpoint_ip: "127.0.0.1", node_name: "rear_vision"]
      }

      {:ok, state} =
        Exporter.init(heartbeat: [interval_ms: 10], config: config, publish: publish_to(self()))

      assert_receive :heartbeat, 1_000
      {:ok, _state} = Exporter.handle_info(:heartbeat, state)

      assert_receive {:published, "ovcs_heartbeat",
                      %StringMessage{data: "rear_vision heartbeat 1" <> _time}}
    end

    test "publishes nothing without its options" do
      {:ok, _state} = Exporter.init(publish: publish_to(self()))

      refute_receive :heartbeat, 50
    end
  end

  describe "through its runner" do
    test "republishes a camera's frame, published under that camera's key, in the frame it carries, and its camera info" do
      start_runner(options(OtherCamera, stereo: []), config(OtherCamera))

      Outputs.publish(
        {:camera_frame, OtherCamera.name_for("left")},
        {:camera_frame, jpeg_frame("left", 1)}
      )

      assert_receive {:published, "stereo/left/image_raw/compressed", %CompressedImage{} = image},
                     1_000

      assert image.data == <<0xFF, 0xD8>>
      assert image.header.frame_id == "left_optical"

      assert_receive {:published, "stereo/left/camera_info", %CameraInfo{} = camera_info}, 1_000
      assert camera_info.header.frame_id == "left_optical"
    end

    test "publishes each pair, in the frame its left frame carries" do
      start_runner(options(OtherCamera, stereo: []), config(OtherCamera))

      Outputs.publish(
        {:stereo_pair, VisionCore.Stereo.Pipeline},
        {:stereo_pair, pair("front_left_optical")}
      )

      assert_receive {:published, "stereo/disparity", %DisparityImage{} = disparity}, 1_000
      assert disparity.header.frame_id == "front_left_optical"
      assert_receive {:published, "stereo/depth/image_rect", %Image{encoding: "16UC1"}}, 1_000
      assert_receive {:published, "stereo/points", _cloud}, 1_000
    end
  end

  describe "a committed calibration" do
    @describetag :tmp_dir

    # A sensor_msgs/SetCameraInfo request as the client hands it to the service: the CDR body.
    defp commit(side, calibration) do
      saved = CameraCalibration.load!(Path.join(@calibration, "#{calibration}_#{side}.yaml"))

      camera_info = %CameraInfo{
        header: %Header{stamp: %Time{}, frame_id: "stereo_#{side}"},
        width: saved.width,
        height: saved.height,
        distortion_model: saved.distortion_model,
        d: saved.distortion_coefficients,
        k: saved.camera_matrix,
        r: saved.rectification_matrix,
        p: saved.projection_matrix
      }

      server = SetCameraInfoServer.name_for("stereo/#{side}/set_camera_info")

      send(
        server,
        {:service_request,
         %{query: %Zenohex.Query{}, request_payload: CameraInfo.encode(camera_info)}}
      )

      :sys.get_state(server)
    end

    defp start_exporter(tmp_dir) do
      config = config(OtherCamera, calibration_store_dir: tmp_dir)

      options =
        OtherCamera
        |> options(stereo: [camera_info_interval_frames: 1])
        |> Keyword.put(:config, config)

      start_supervised!(
        {VisionCore.Exporter.Supervisor, exporter: Exporter, options: options, config: config}
      )
    end

    defp runner_pid(supervisor) do
      {Runner, runner, :worker, _modules} =
        supervisor |> Supervisor.which_children() |> List.keyfind(Runner, 0)

      runner
    end

    # The exporter's runner, once it is done with what was sent to it before.
    defp runner(supervisor) do
      runner = runner_pid(supervisor)
      :sys.get_state(runner)
      runner
    end

    defp left_camera_info do
      Outputs.publish(
        {:camera_frame, OtherCamera.name_for("left")},
        {:camera_frame, jpeg_frame("left", 1)}
      )

      assert_receive {:published, "stereo/left/camera_info", %CameraInfo{} = camera_info}, 1_000
      camera_info
    end

    # The stereo unit's pipeline, which takes the calibrations committed.
    defp start_pipeline do
      start_supervised!(
        {VisionCore.Stereo.Pipeline,
         left_calibration_path: Path.join(@calibration, "identity_left.yaml"),
         right_calibration_path: Path.join(@calibration, "identity_right.yaml"),
         width: 64,
         height: 48,
         defn_options: Application.fetch_env!(:vision_core, :nx_defn_options)}
      )
    end

    test "is published as each side's camera info once both sides are stored and the stereo unit took them",
         %{tmp_dir: tmp_dir} do
      start_pipeline()
      supervisor = start_exporter(tmp_dir)
      runner(supervisor)
      before = left_camera_info()

      commit(:left, :distorted)
      runner(supervisor)
      assert left_camera_info().d == before.d

      commit(:right, :distorted)
      runner(supervisor)
      refute left_camera_info().d == before.d
    end

    test "is not published while the stereo unit has not taken it", %{tmp_dir: tmp_dir} do
      supervisor = start_exporter(tmp_dir)
      runner(supervisor)
      before = left_camera_info()

      commit(:left, :distorted)
      commit(:right, :distorted)
      runner(supervisor)

      assert left_camera_info().d == before.d
    end

    test "stays the camera info published after a restart of the exporter's runner",
         %{tmp_dir: tmp_dir} do
      start_pipeline()
      supervisor = start_exporter(tmp_dir)
      runner = runner(supervisor)
      before = left_camera_info()
      commit(:left, :distorted)
      commit(:right, :distorted)

      Process.exit(runner, :kill)
      eventually(fn -> is_pid(runner_pid(supervisor)) and runner_pid(supervisor) != runner end)
      runner(supervisor)

      refute left_camera_info().d == before.d
    end
  end

  defp eventually(check, attempts \\ 100) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(10) && eventually(check, attempts - 1)
    end
  end

  test "publishes the rest of a pair when one of its messages is not sent" do
    test = self()

    publish = fn
      "stereo/depth/image_rect", _module, _message, _options ->
        {:error, {:encode_raised, "no depth"}}

      topic, _module, message, _options ->
        send(test, {:published, topic, message})
        :ok
    end

    {:ok, state} = Exporter.init(Keyword.put(options(Camera, stereo: []), :publish, publish))

    assert {:ok, _state} = Exporter.handle_output(:stereo_pair, %Pair{pair() | depth: nil}, state)
    assert_received {:published, "stereo/disparity", %DisparityImage{}}
    assert_received {:published, "stereo/points", _cloud}
  end

  test "times a camera frame's raw image, not the camera info published with it" do
    test = self()

    publish = fn
      _topic, CameraInfo, _message, _options ->
        Process.sleep(100)
        :ok

      topic, _module, _message, _options ->
        send(test, {:published, topic})
        :ok
    end

    {:ok, state} = Exporter.init(Keyword.put(options(Camera, stereo: []), :publish, publish))
    jpeg = %Frame{label: "left", width: 2, height: 2, capture_ns: 1, jpeg: <<0xFF, 0xD8>>}

    {:ok, state} = Exporter.handle_output({:camera_frame, :left}, jpeg, state)

    assert_received {:published, "stereo/left/image_raw/compressed"}
    assert [publish_ns] = state.telemetry.stages.pub_left
    assert publish_ns < 100_000_000
  end

  test "publishes the detections in the frame of their pair, deleting the markers of those gone since the last result" do
    {:ok, state} = Exporter.init(options(Camera, detections: []))

    {:ok, state} =
      Exporter.handle_output(
        :detections,
        {pair(), [detection("person"), detection("car")]},
        state
      )

    assert_received {:published, "stereo/detections/markers",
                     %MarkerArray{markers: [marker | _markers]}}

    assert marker.header.frame_id == "stereo_left_optical"
    assert_received {:published, "stereo/left/detections", %ImageAnnotations{}}

    {:ok, _state} = Exporter.handle_output(:detections, {pair(), [detection("person")]}, state)

    assert_received {:published, "stereo/detections/markers", %MarkerArray{markers: markers}}

    assert Enum.map(markers, & &1.action) ==
             List.duplicate(Marker.add(), 2) ++ List.duplicate(Marker.delete(), 2)
  end

  test "has the client keep the marker array that deletes the markers of boxes gone" do
    test = self()
    publish = fn topic, _module, _message, options -> send(test, {:published, topic, options}) end
    {:ok, state} = Exporter.init(Keyword.put(options(Camera, detections: []), :publish, publish))

    {:ok, state} =
      Exporter.handle_output(
        :detections,
        {pair(), [detection("person"), detection("car")]},
        state
      )

    assert_received {:published, "stereo/detections/markers", [keep: false]}

    {:ok, _state} = Exporter.handle_output(:detections, {pair(), [detection("person")]}, state)

    assert_received {:published, "stereo/detections/markers", [keep: true]}
  end

  describe "on its own JPEG codec" do
    @describetag :jpeg

    setup do
      codec = Module.concat(__MODULE__, Codec)
      start_supervised!({VisionCore.Jpeg, name: codec})
      %{codec: codec}
    end

    test "encodes the grey raw images and the rectified images on the codec it is given",
         %{codec: codec} do
      refute Process.whereis(VisionCore.Jpeg)

      {:ok, state} =
        Exporter.init(options(Camera, stereo: [publish_rectified_image: true], jpeg_codec: codec))

      grey = %Frame{label: "left", width: 2, height: 2, capture_ns: 1, grey: <<0, 64, 128, 255>>}
      {:ok, state} = Exporter.handle_output({:camera_frame, :left}, grey, state)

      assert_received {:published, "stereo/left/image_raw/compressed",
                       %CompressedImage{data: raw}}

      assert <<0xFF, 0xD8, _rest::binary>> = raw

      {:ok, _state} = Exporter.handle_output(:stereo_pair, pair(), state)

      assert_received {:published, "stereo/left/image_rect/compressed",
                       %CompressedImage{data: rectified}}

      assert <<0xFF, 0xD8, _rest::binary>> = rectified
    end
  end
end

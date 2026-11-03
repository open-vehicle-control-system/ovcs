defmodule VisionCore.Ros2.ExporterTest do
  # Publishes pairs under the stereo pipeline's key, which other tests subscribe to.
  use ExUnit.Case, async: false

  alias Ros2Zenoh.FoxgloveMsgs.Msg.ImageAnnotations
  alias Ros2Zenoh.SensorMsgs.Msg.{CameraInfo, CompressedImage, Image}
  alias Ros2Zenoh.StdMsgs.Msg.String, as: StringMessage
  alias Ros2Zenoh.StereoMsgs.Msg.DisparityImage
  alias Ros2Zenoh.VisualizationMsgs.Msg.{Marker, MarkerArray}
  alias VisionCore.Camera.Frame
  alias VisionCore.Exporter.Runner
  alias VisionCore.Outputs
  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Ros2.Exporter
  alias VisionCore.Ros2.Exporter.Diagnostics
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

  defp stereo_options(driver \\ Camera),
    do: [
      driver: driver,
      left: [frame_id: "stereo_left_optical"],
      right: [frame_id: "stereo_right_optical"]
    ]

  defp pair do
    frame = %Frame{label: "left", width: 8, height: 4, capture_ns: 0, grey: <<>>}

    %Pair{
      left_frame: frame,
      right_frame: frame,
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
    do: %Frame{label: label, width: 2, height: 2, capture_ns: capture_ns, jpeg: <<0xFF, 0xD8>>}

  defp config(driver),
    do: %VisionCore.Config{
      zenoh_endpoint_ip: "127.0.0.1",
      components: [{:stereo, driver: driver, left: [], right: []}]
    }

  # Started, and done with the exporter's init/1, so subscribed.
  defp start_runner(options, driver) do
    runner =
      start_supervised!({Runner, exporter: Exporter, options: options, config: config(driver)})

    :sys.get_state(runner)
    runner
  end

  describe "outputs/1" do
    test "reads the stereo unit's pairs and frames, and the detections, each when it publishes them" do
      assert Exporter.outputs(stereo: stereo_options(), detections: []) == [
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

      assert [{Diagnostics, options}] =
               Exporter.children(stereo: stereo_options(), publish: publish)

      assert options[:driver] == Camera
      assert options[:publish] == publish
      assert Exporter.children(heartbeat: []) == []
    end
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

    test "publishes nothing without its options" do
      {:ok, _state} = Exporter.init(publish: publish_to(self()))

      refute_receive :heartbeat, 50
    end
  end

  describe "through its runner" do
    test "republishes a camera's frame, published under that camera's key, and its camera info" do
      start_runner(
        [stereo: stereo_options(OtherCamera), publish: publish_to(self())],
        OtherCamera
      )

      Outputs.publish(
        {:camera_frame, OtherCamera.name_for("left")},
        {:camera_frame, jpeg_frame("left", 1)}
      )

      assert_receive {:published, "stereo/left/image_raw/compressed", %CompressedImage{} = image},
                     1_000

      assert image.data == <<0xFF, 0xD8>>
      assert image.header.frame_id == "stereo_left_optical"
      assert_receive {:published, "stereo/left/camera_info", %CameraInfo{}}, 1_000
    end

    test "publishes each pair: the disparity, the depth and the cloud" do
      start_runner(
        [stereo: stereo_options(OtherCamera), publish: publish_to(self())],
        OtherCamera
      )

      Outputs.publish({:stereo_pair, VisionCore.Stereo.Pipeline}, {:stereo_pair, pair()})

      assert_receive {:published, "stereo/disparity", %DisparityImage{}}, 1_000
      assert_receive {:published, "stereo/depth/image_rect", %Image{encoding: "16UC1"}}, 1_000
      assert_receive {:published, "stereo/points", _cloud}, 1_000
    end

    test "reads each side's camera info again when told a calibration was committed" do
      start_runner(
        [
          name: Module.concat(__MODULE__, Reloaded),
          stereo:
            Keyword.merge(stereo_options(OtherCamera),
              camera_info_interval_frames: 1,
              width: 64,
              height: 48,
              left: [calibration_path: Path.join(@calibration, "stereo_left.yaml")]
            ),
          publish: publish_to(self())
        ],
        OtherCamera
      )

      publish_frame = fn ->
        Outputs.publish(
          {:camera_frame, OtherCamera.name_for("left")},
          {:camera_frame, jpeg_frame("left", 1)}
        )

        assert_receive {:published, "stereo/left/camera_info", %CameraInfo{} = camera_info},
                       1_000

        camera_info
      end

      before = publish_frame.()

      assert :ok =
               Exporter.reload_calibration(Module.concat(__MODULE__, Reloaded),
                 left_calibration_path: Path.join(@calibration, "distorted_left.yaml")
               )

      refute publish_frame.().d == before.d
    end
  end

  test "a calibration reload reaches no exporter when none runs" do
    assert Exporter.reload_calibration(Module.concat(__MODULE__, NotRunning), []) == :ok
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

    {:ok, state} = Exporter.init(stereo: stereo_options(), publish: publish)

    assert {:ok, _state} = Exporter.handle_output(:stereo_pair, %Pair{pair() | depth: nil}, state)
    assert_received {:published, "stereo/disparity", %DisparityImage{}}
    assert_received {:published, "stereo/points", _cloud}
  end

  test "publishes the detections, deleting the markers of those gone since the last result" do
    {:ok, state} = Exporter.init(detections: [], publish: publish_to(self()))

    {:ok, state} =
      Exporter.handle_output(
        :detections,
        {pair(), [detection("person"), detection("car")]},
        state
      )

    assert_received {:published, "stereo/detections/markers", %MarkerArray{}}
    assert_received {:published, "stereo/left/detections", %ImageAnnotations{}}

    {:ok, _state} = Exporter.handle_output(:detections, {pair(), [detection("person")]}, state)

    assert_received {:published, "stereo/detections/markers", %MarkerArray{markers: markers}}

    assert Enum.map(markers, & &1.action) ==
             List.duplicate(Marker.add(), 2) ++ List.duplicate(Marker.delete(), 2)
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
        Exporter.init(
          stereo: stereo_options() ++ [publish_rectified_image: true],
          jpeg_codec: codec,
          publish: publish_to(self())
        )

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

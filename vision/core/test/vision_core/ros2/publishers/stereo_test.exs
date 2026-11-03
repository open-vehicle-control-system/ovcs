defmodule VisionCore.Ros2.Publishers.StereoTest do
  use ExUnit.Case, async: false

  alias VisionCore.Ros2.Publishers.Stereo

  @side_opts [frame_id: "left_camera"]
  @calibration Path.expand("../../../support/calibration", __DIR__)

  describe "a stereo pair" do
    alias Ros2Zenoh.SensorMsgs.Msg.{Image, PointCloud2}
    alias Ros2Zenoh.StereoMsgs.Msg.DisparityImage
    alias VisionCore.Camera.Frame
    alias VisionCore.Outputs
    alias VisionCore.Stereo.Pair

    @moduletag :capture_log

    # Names the camera drivers and the pipeline, which need not be running.
    defmodule Source do
      def name_for(label), do: Module.concat(__MODULE__, label)
    end

    # Stands in for VisionCore.Ros2.ZenohClient: hands every publish to the test.
    defmodule ZenohClient do
      use GenServer

      def start_link(test),
        do: GenServer.start_link(__MODULE__, test, name: VisionCore.Ros2.ZenohClient)

      @impl GenServer
      def init(test), do: {:ok, test}

      @impl GenServer
      def handle_cast({:publish, topic, _module, message, _payload, _opts}, test) do
        send(test, {:published, topic, message})
        {:noreply, test}
      end
    end

    setup do
      start_supervised!({ZenohClient, self()})

      start_supervised!(
        {Stereo,
         cameras: [{Source, "left"}, {Source, "right"}],
         topic_prefix: "stereo",
         disparity_topic: "stereo/disparity",
         depth_topic: "stereo/depth/image_rect",
         cloud_topic: "stereo/points",
         left: @side_opts,
         right: @side_opts,
         width: 8,
         height: 4,
         pipeline: Source.name_for("pipeline")}
      )

      :ok
    end

    defp pair do
      frame = %Frame{label: "left", width: 8, height: 4, capture_ns: 0, grey: <<>>}

      %Pair{
        left_frame: frame,
        right_frame: frame,
        left: Nx.broadcast(Nx.u8(0), {4, 8}),
        geometry: %{focal_length_px: 600.0, baseline_m: 0.08, left_calibration: nil},
        disparity_range: %{min_disparity: 0, num_disparities: 2, block_size: 1},
        disparity_scale: 16,
        disparity_bytes: :binary.copy(<<0::32>>, 32),
        depth: :binary.copy(<<0::16>>, 32),
        cloud: :binary.copy(<<0::32>>, 3 * 2),
        cloud_points: 2,
        cloud_size: {1, 2}
      }
    end

    # As the pipeline publishes it.
    defp publish_pair(pair),
      do: Outputs.publish({:stereo_pair, Source.name_for("pipeline")}, {:stereo_pair, pair})

    test "publishes the disparity, the depth in millimetres and the organized point cloud" do
      publish_pair(pair())

      assert_receive {:published, "stereo/disparity", %DisparityImage{} = disparity}
      assert %{width: 8, height: 4, encoding: "32FC1", step: 32} = disparity.image
      assert {disparity.f, disparity.t} == {600.0, 0.08}

      assert {disparity.min_disparity, disparity.max_disparity, disparity.delta_d} ==
               {0.0, 1.0, 0.0625}

      assert %{x_offset: 2, y_offset: 0, width: 5, height: 3} = disparity.valid_window

      assert_receive {:published, "stereo/depth/image_rect", %Image{} = depth}
      assert %{width: 8, height: 4, encoding: "16UC1", step: 16} = depth

      assert_receive {:published, "stereo/points", %PointCloud2{} = cloud}
      assert %{height: 1, width: 2, is_dense: 0} = cloud
      assert cloud.row_step == 2 * cloud.point_step
    end

    test "drops a message that does not encode and publishes the rest of the pair" do
      publisher = Process.whereis(Stereo)

      publish_pair(%Pair{pair() | depth: nil})

      assert_receive {:published, "stereo/disparity", %DisparityImage{}}
      assert_receive {:published, "stereo/points", %PointCloud2{}}
      refute_receive {:published, "stereo/depth/image_rect", _depth}
      assert Process.whereis(Stereo) == publisher
    end
  end

  test "republishes the raw images by default" do
    side = Stereo.build_side_state("left", "stereo", @side_opts, 4, 4, true)
    assert side.image_topic == "stereo/left/image_raw/compressed"
  end

  test "keeps the camera info but not the raw images when told not to republish them" do
    side = Stereo.build_side_state("left", "stereo", @side_opts, 4, 4, false)
    refute side.image_topic
    assert side.camera_info_topic == "stereo/left/camera_info"
  end

  test "reloads a side's camera info from the calibration a commit rewrote" do
    path =
      Path.join(
        System.tmp_dir!(),
        "stereo_publisher_left_#{System.unique_integer([:positive])}.yaml"
      )

    File.cp!(Path.join(@calibration, "stereo_left.yaml"), path)

    side =
      Stereo.build_side_state(
        "left",
        "stereo",
        [calibration_path: path] ++ @side_opts,
        64,
        48,
        true
      )

    File.cp!(Path.join(@calibration, "distorted_left.yaml"), path)
    reloaded = Stereo.reload_side_calibration(side, nil)

    refute reloaded.camera_info.k == side.camera_info.k
    assert reloaded.camera_info.d != side.camera_info.d
  end

  test "reloads a side's camera info from a new calibration path" do
    side =
      Stereo.build_side_state(
        "left",
        "stereo",
        [calibration_path: Path.join(@calibration, "stereo_left.yaml")] ++ @side_opts,
        64,
        48,
        true
      )

    reloaded =
      Stereo.reload_side_calibration(side, Path.join(@calibration, "distorted_left.yaml"))

    refute reloaded.camera_info.d == side.camera_info.d
    assert reloaded.calibration_path == Path.join(@calibration, "distorted_left.yaml")
  end

  describe "raw image rate" do
    alias VisionCore.Camera.Frame

    defp published(frame, max_hz) do
      {count, _next} =
        Enum.reduce(0..29, {0, nil}, fn index, {count, next_ms} ->
          case Stereo.image_slot(next_ms, frame, index * 33, max_hz) do
            {:publish, next_ms} -> {count + 1, next_ms}
            :skip -> {count, next_ms}
          end
        end)

      count
    end

    test "grey frames are encoded and published at most max_hz" do
      grey = %Frame{label: "left", width: 1, height: 1, capture_ns: 0, grey: <<0>>}
      assert published(grey, 10) in 9..10
    end

    test "JPEG frames are published as they arrive" do
      jpeg = %Frame{label: "left", width: 1, height: 1, capture_ns: 0, jpeg: <<0xFF, 0xD8>>}
      assert published(jpeg, 10) == 30
    end
  end

  describe "rectified images" do
    @describetag :jpeg

    test "a tensor from the Nx stages is encoded" do
      start_supervised!(VisionCore.Jpeg)
      image = Nx.iota({12, 16}, type: :u8)

      assert {:ok, <<0xFF, 0xD8, _rest::binary>>} = Stereo.encode_image(image)
    end
  end
end

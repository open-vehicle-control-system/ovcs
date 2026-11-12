defmodule VisionCore.Ros2.Exporter.SegmentationTest do
  use ExUnit.Case, async: true

  alias Ros2Zenoh.SensorMsgs.Msg.{Image, PointCloud2}
  alias Ros2Zenoh.StdMsgs.Msg.Header
  alias VisionCore.Camera.Frame
  alias VisionCore.Ros2.Exporter.Segmentation
  alias VisionCore.Ros2.Stamp

  @capture_ns 1_234_567_890
  @pair_capture_ns 1_200_000_000

  defp frame(frame_id \\ "hq_optical"),
    do: %Frame{label: "hq", frame_id: frame_id, width: 8, height: 6, capture_ns: @capture_ns}

  # A 4 x 2 grid over the frame's bottom band: sky on the top row, road on the bottom one.
  defp labels,
    do: %{width: 4, height: 2, data: <<10, 10, 10, 10, 0, 0, 0, 0>>, band: {0, 2, 8, 4}}

  defp xyz(points),
    do:
      for(
        {x, y, z} <- points,
        into: <<>>,
        do: <<x::float-32-little, y::float-32-little, z::float-32-little>>
      )

  defp clouds(frame_id \\ "stereo_left_optical"),
    do: %{
      road: xyz([{0.5, 1.0, 4.0}, {-0.5, 1.0, 4.5}]),
      off_road: xyz([{0.0, -2.0, 9.0}]),
      frame_id: frame_id,
      capture_ns: @pair_capture_ns
    }

  defp settings(options \\ []),
    do:
      Segmentation.new(
        [pipeline: :road, camera_frame_id: "hq_frame", cloud_frame_id: "front_left"] ++ options
      )

  test "publishes on <prefix>/<name>/labels, road/points and off_road/points" do
    settings = settings(topic_prefix: "front")

    assert settings.labels_topic == "front/road/labels"
    assert settings.road_topic == "front/road/road/points"
    assert settings.off_road_topic == "front/road/off_road/points"

    assert Segmentation.new(pipeline: :lanes).labels_topic == "stereo/lanes/labels"
  end

  test "refuses an option it does not take" do
    assert_raise ArgumentError, ~r/:topic/, fn ->
      Segmentation.new(pipeline: :road, topic: "a")
    end
  end

  test "the label image is a mono8 image of the grid's class ids, in the camera's frame at its capture time" do
    assert [{"stereo/road/labels", Image, image} | _clouds] =
             Segmentation.messages(frame(), labels(), clouds(), settings())

    assert image == %Image{
             header: %Header{
               stamp: Stamp.stamp_from_monotonic(@capture_ns),
               frame_id: "hq_optical"
             },
             height: 2,
             width: 4,
             encoding: "mono8",
             is_bigendian: 0,
             step: 4,
             data: <<10, 10, 10, 10, 0, 0, 0, 0>>
           }
  end

  test "the clouds are the road and off-road points in the stereo left frame, at their pair's capture time" do
    assert [
             _labels,
             {"stereo/road/road/points", PointCloud2, road},
             {"stereo/road/off_road/points", PointCloud2, off_road}
           ] = Segmentation.messages(frame(), labels(), clouds(), settings())

    header = %Header{
      stamp: Stamp.stamp_from_monotonic(@pair_capture_ns),
      frame_id: "stereo_left_optical"
    }

    assert road == %PointCloud2{
             header: header,
             height: 1,
             width: 2,
             fields: PointCloud2.xyz_fields(),
             is_bigendian: 0,
             point_step: 12,
             row_step: 24,
             data: clouds().road,
             is_dense: 1
           }

    assert %PointCloud2{header: ^header, width: 1, row_step: 12, data: data} = off_road
    assert data == clouds().off_road
  end

  test "a result without clouds publishes its label image alone" do
    assert [{"stereo/road/labels", Image, _image}] =
             Segmentation.messages(frame(), labels(), nil, settings())
  end

  test "a result whose points all fall outside the band publishes empty clouds, which encode" do
    empty = %{clouds() | road: <<>>, off_road: <<>>}

    assert [_labels, {_road_topic, PointCloud2, road}, {_off_road_topic, PointCloud2, off_road}] =
             Segmentation.messages(frame(), labels(), empty, settings())

    assert %PointCloud2{width: 0, row_step: 0, data: <<>>} = road
    assert %PointCloud2{width: 0} = off_road
    assert is_binary(PointCloud2.encode(road))
  end

  test "a frame or a pair without a frame id takes the camera's and the stereo left one's" do
    assert [
             {_topic, Image, image},
             {_road, PointCloud2, road},
             {_off_road, PointCloud2, off_road}
           ] =
             Segmentation.messages(frame(nil), labels(), clouds(nil), settings())

    assert image.header.frame_id == "hq_frame"
    assert road.header.frame_id == "front_left"
    assert off_road.header.frame_id == "front_left"
  end

  test "frame ids default to the camera's optical frame and the prefix's left one" do
    settings = Segmentation.new(pipeline: :road, camera: :hq, topic_prefix: "front")

    assert [{_topic, Image, image}, {_road, PointCloud2, road}, _off_road] =
             Segmentation.messages(frame(nil), labels(), clouds(nil), settings)

    assert image.header.frame_id == "hq_optical"
    assert road.header.frame_id == "front_left"
  end
end

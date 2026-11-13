defmodule VisionCore.Ros2.Exporter.DetectionsTest do
  use ExUnit.Case, async: true

  alias Ros2Zenoh.FoxgloveMsgs.Msg.ImageAnnotations
  alias Ros2Zenoh.VisionMsgs.Msg.{Detection2DArray, Detection3DArray}
  alias Ros2Zenoh.VisualizationMsgs.Msg.{Marker, MarkerArray}
  alias VisionCore.Camera.Frame
  alias VisionCore.Ros2.Exporter.Detections
  alias VisionCore.Stereo.Pair

  defp pair do
    frame = %Frame{label: "left", width: 80, height: 40, capture_ns: 0, grey: <<>>}
    %Pair{left_frame: frame, right_frame: frame, geometry: %{width: 40, height: 20}}
  end

  # As the detection pipeline places it, its outline already on the captured image.
  defp detection(label, outline) do
    %{
      label: label,
      score: 0.8,
      class_id: 0,
      x: 0.1,
      y: 0.2,
      z: 2.0,
      width: 0.5,
      height: 1.0,
      depth: 0.1,
      outline: outline,
      caption: "#{label} 0.80 2.00m"
    }
  end

  defp square(x, y), do: [{x, y}, {x + 20.0, y}, {x + 20.0, y + 20.0}, {x, y + 20.0}]

  defp messages(detections, drawn \\ 0) do
    assert [
             {"stereo/detection/detections/markers", MarkerArray, %MarkerArray{markers: markers},
              _options},
             {"stereo/detection/detections", Detection3DArray, array},
             {"stereo/detection/annotations", ImageAnnotations, overlay}
           ] = Detections.messages(detections, pair(), Detections.new([]), drawn)

    {markers, array, overlay}
  end

  test "makes a box and a label marker per detection, under ids that do not collide" do
    {markers, array, _overlay} =
      messages([detection("person", square(0.0, 0.0)), detection("car", square(40.0, 10.0))])

    assert Enum.map(markers, &{&1.id, &1.type}) == [
             {0, Marker.cube()},
             {1, Marker.text_view_facing()},
             {2, Marker.cube()},
             {3, Marker.text_view_facing()}
           ]

    assert Enum.all?(markers, &(&1.ns == "detection"))

    assert Enum.map(array.detections, & &1.id) == ["0", "1"]
    assert Enum.at(markers, 1).text == "person 0.80 2.00m"
  end

  test "deletes the markers of a box gone since the result drawn before" do
    {markers, _array, _overlay} = messages([detection("person", square(0.0, 0.0))], 2)

    assert Enum.map(markers, &{&1.id, &1.action}) == [
             {0, Marker.add()},
             {1, Marker.add()},
             {2, Marker.delete()},
             {3, Marker.delete()}
           ]
  end

  test "keeps a marker array that deletes markers, which the arrays after it do not delete again" do
    person = [detection("person", square(0.0, 0.0))]

    assert [{_topic, MarkerArray, _array, keep: true} | _messages] =
             Detections.messages(person, pair(), Detections.new([]), 2)

    assert [{_topic, MarkerArray, _array, keep: false} | _messages] =
             Detections.messages(person, pair(), Detections.new([]), 1)
  end

  test "outlines each box on the captured image, its caption above its first vertex" do
    {_markers, _array, overlay} =
      messages([
        detection("person", square(0.0, 20.0)),
        detection("car", square(40.0, 10.0))
      ])

    assert [person, car] = overlay.points

    assert Enum.map(person.points, &{&1.x, &1.y}) == [
             {0.0, 20.0},
             {20.0, 20.0},
             {20.0, 40.0},
             {0.0, 40.0}
           ]

    assert length(car.points) == 4

    assert [
             %{position: %{x: +0.0, y: 16.0}, text: "person 0.80 2.00m"},
             %{position: %{x: 40.0, y: 10.0}, text: "car 0.80 2.00m"}
           ] = overlay.texts
  end

  test "stamps everything in the frame of the pair, under the prefix it is given" do
    settings = Detections.new(topic_prefix: "front")
    pair = put_in(pair().left_frame.frame_id, "front_left_optical")
    messages = Detections.messages([detection("person", square(0.0, 0.0))], pair, settings, 0)

    assert Enum.map(messages, &elem(&1, 0)) == [
             "front/detection/detections/markers",
             "front/detection/detections",
             "front/detection/annotations"
           ]

    assert {_topic, Detection3DArray, array} = Enum.at(messages, 1)
    assert array.header.frame_id == "front_left_optical"
  end

  test "publishes a named pipeline's detections under its name, its markers in its own namespace" do
    settings = Detections.new(topic_prefix: "front", pipeline: :road)
    messages = Detections.messages([detection("lane", square(0.0, 0.0))], pair(), settings, 2)

    assert [
             {"front/road/detections/markers", MarkerArray, %MarkerArray{markers: markers},
              keep: true},
             {"front/road/detections", Detection3DArray, array},
             {"front/road/annotations", ImageAnnotations, _overlay}
           ] = messages

    assert Enum.map(markers, &{&1.ns, &1.id, &1.action}) == [
             {"road", 0, Marker.add()},
             {"road", 1, Marker.add()},
             {"road", 2, Marker.delete()},
             {"road", 3, Marker.delete()}
           ]

    assert array.header.frame_id == "front_left"
  end

  test "stamps the detections of a pair without a frame id in the prefix's left frame" do
    settings = Detections.new(topic_prefix: "front")
    messages = Detections.messages([detection("person", square(0.0, 0.0))], pair(), settings, 0)

    assert {_topic, Detection3DArray, array} = Enum.at(messages, 1)
    assert array.header.frame_id == "front_left"
  end

  describe "on a camera source" do
    defp camera_frame do
      %Frame{label: "hq", frame_id: "hq_optical", width: 1014, height: 760, capture_ns: 5_000_000}
    end

    # As the detection pipeline keeps a box out of the stereo view: its box and bearing, no position.
    defp unplaced(label, outline) do
      [{x0, y0}, _top_right, {x1, y1}, _bottom_left] = outline

      label
      |> detection(outline)
      |> Map.merge(%{x: nil, y: nil, z: nil, width: nil, height: nil, depth: nil})
      |> Map.merge(%{
        box: %{x0: x0, y0: y0, x1: x1, y1: y1},
        bearing: {0.1, 0.0},
        caption: "#{label} 0.80"
      })
    end

    defp camera_messages(detections, drawn \\ 0) do
      settings = Detections.new(topic_prefix: "front", pipeline: :hq_people)
      Detections.messages(detections, camera_frame(), settings, drawn)
    end

    test "publishes the detections with a distance in 3D, the others in 2D, all in the camera's frame" do
      assert [
               {"front/hq_people/detections/markers", MarkerArray, %MarkerArray{markers: markers},
                keep: false},
               {"front/hq_people/detections", Detection3DArray, array_3d},
               {"front/hq_people/detections_2d", Detection2DArray, array_2d},
               {"front/hq_people/annotations", ImageAnnotations, overlay}
             ] =
               camera_messages([
                 detection("person", square(0.0, 0.0)),
                 unplaced("car", square(40.0, 10.0))
               ])

      assert Enum.map(markers, & &1.id) == [0, 1]
      assert [%{id: "0"}] = array_3d.detections
      assert [%{id: "1", results: [result], bbox: bbox}] = array_2d.detections
      assert %{class_id: "car", score: 0.8} = result.hypothesis

      assert {bbox.center.position.x, bbox.center.position.y, bbox.size_x, bbox.size_y} ==
               {50.0, 20.0, 20.0, 20.0}

      for header <- [array_3d.header, array_2d.header, hd(markers).header],
          do: assert(header.frame_id == "hq_optical")

      assert array_2d.header.stamp == array_3d.header.stamp
      assert Enum.map(overlay.texts, & &1.text) == ["person 0.80 2.00m", "car 0.80"]
    end

    test "draws the 2D boxes and the overlay on an image of another size, pixel centres on pixel centres" do
      settings =
        Detections.new(topic_prefix: "front", pipeline: :hq_people, image_size: {2028, 1520})

      messages =
        Detections.messages([unplaced("car", square(40.0, 10.0))], camera_frame(), settings, 0)

      {_topic, Detection2DArray, %{detections: [%{bbox: bbox}]}} =
        List.keyfind(messages, Detection2DArray, 1)

      assert {bbox.center.position.x, bbox.center.position.y, bbox.size_x, bbox.size_y} ==
               {100.5, 40.5, 40.0, 40.0}

      {_topic, ImageAnnotations, overlay} = List.keyfind(messages, ImageAnnotations, 1)
      assert [%{points: points}] = overlay.points

      assert Enum.map(points, &{&1.x, &1.y}) == [
               {80.5, 20.5},
               {120.5, 20.5},
               {120.5, 60.5},
               {80.5, 60.5}
             ]
    end

    test "publishes an empty Detection2DArray once every detection has a distance, so the last goes" do
      assert {_topic, Detection2DArray, %Detection2DArray{detections: []}} =
               List.keyfind(
                 camera_messages([detection("person", square(0.0, 0.0))]),
                 Detection2DArray,
                 1
               )
    end

    test "draws markers only for the detections with a distance, and deletes those gone" do
      [{_topic, MarkerArray, %MarkerArray{markers: markers}, keep: true} | _rest] =
        camera_messages([unplaced("car", square(40.0, 10.0))], 1)

      assert Enum.map(markers, &{&1.id, &1.action}) == [
               {0, Marker.delete()},
               {1, Marker.delete()}
             ]

      assert Detections.drawn([
               detection("person", square(0.0, 0.0)),
               unplaced("car", square(40.0, 10.0))
             ]) == 1
    end
  end
end

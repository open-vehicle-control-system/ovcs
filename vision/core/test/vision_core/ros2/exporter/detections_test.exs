defmodule VisionCore.Ros2.Exporter.DetectionsTest do
  use ExUnit.Case, async: true

  alias Ros2Zenoh.FoxgloveMsgs.Msg.ImageAnnotations
  alias Ros2Zenoh.VisionMsgs.Msg.Detection3DArray
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
             {"stereo/detections/markers", MarkerArray, %MarkerArray{markers: markers}},
             {"stereo/detections", Detection3DArray, array},
             {"stereo/left/detections", ImageAnnotations, overlay}
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

  test "stamps everything in the frame it is given, under the prefix it is given" do
    settings = Detections.new(topic_prefix: "front", frame_id: "front_left_optical")
    messages = Detections.messages([detection("person", square(0.0, 0.0))], pair(), settings, 0)

    assert Enum.map(messages, &elem(&1, 0)) == [
             "front/detections/markers",
             "front/detections",
             "front/left/detections"
           ]

    assert {_topic, Detection3DArray, array} = Enum.at(messages, 1)
    assert array.header.frame_id == "front_left_optical"
  end
end

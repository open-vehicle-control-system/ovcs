defmodule VisionCore.Ros2.Publishers.DetectionsTest do
  use ExUnit.Case, async: false

  alias Ros2Zenoh.FoxgloveMsgs.Msg.ImageAnnotations
  alias Ros2Zenoh.VisionMsgs.Msg.Detection3DArray
  alias Ros2Zenoh.VisualizationMsgs.Msg.{Marker, MarkerArray}
  alias VisionCore.Camera.Frame
  alias VisionCore.Ros2.Publishers.Detections
  alias VisionCore.Stereo.Pair

  @moduletag :capture_log

  # Stands in for VisionCore.Ros2.ZenohClient: hands every publish to the test.
  defmodule ZenohClient do
    use GenServer

    def start_link(test),
      do: GenServer.start_link(__MODULE__, test, name: VisionCore.Ros2.ZenohClient)

    @impl GenServer
    def init(test), do: {:ok, test}

    @impl GenServer
    def handle_cast({:publish, topic, _module, message, _opts}, test) do
      send(test, {:published, topic, message})
      {:noreply, test}
    end
  end

  # Matched at half the 80x40 frame, without calibration: outlines only scale.
  defp pair do
    frame = %Frame{label: "left", width: 80, height: 40, capture_ns: 0, grey: <<>>}

    %Pair{
      left_frame: frame,
      right_frame: frame,
      left: Nx.broadcast(Nx.u8(0), {20, 40}),
      geometry: %{width: 40, height: 20, left_calibration: nil}
    }
  end

  defp detection(label, box) do
    %{
      label: label,
      score: 0.8,
      class_id: 0,
      box: box,
      x: 0.1,
      y: 0.2,
      z: 2.0,
      width: 0.5,
      height: 1.0,
      depth: 0.1
    }
  end

  defp publish(detections) do
    GenServer.cast(Detections, {:detections, pair(), detections})
    assert_receive {:published, "stereo/detections/markers", %MarkerArray{markers: markers}}
    assert_receive {:published, "stereo/detections", %Detection3DArray{} = array}
    assert_receive {:published, "stereo/left/detections", %ImageAnnotations{} = overlay}
    {markers, array, overlay}
  end

  setup do
    start_supervised!({ZenohClient, self()})
    start_supervised!({Detections, outline_segments: 1})
    :ok
  end

  test "publishes a box and a label marker per detection, under ids that do not collide" do
    {markers, array, _overlay} =
      publish([
        detection("person", %{x0: 0.0, y0: 0.0, x1: 10.0, y1: 10.0}),
        detection("car", %{x0: 20.0, y0: 5.0, x1: 30.0, y1: 15.0})
      ])

    assert Enum.map(markers, &{&1.id, &1.type}) == [
             {0, Marker.cube()},
             {1, Marker.text_view_facing()},
             {2, Marker.cube()},
             {3, Marker.text_view_facing()}
           ]

    assert Enum.map(array.detections, & &1.id) == ["0", "1"]
  end

  test "deletes the markers of a box gone since the last result" do
    publish([
      detection("person", %{x0: 0.0, y0: 0.0, x1: 10.0, y1: 10.0}),
      detection("car", %{x0: 20.0, y0: 5.0, x1: 30.0, y1: 15.0})
    ])

    {markers, _array, _overlay} =
      publish([detection("person", %{x0: 0.0, y0: 0.0, x1: 10.0, y1: 10.0})])

    assert Enum.map(markers, &{&1.id, &1.action}) == [
             {0, Marker.add()},
             {1, Marker.add()},
             {2, Marker.delete()},
             {3, Marker.delete()}
           ]
  end

  test "outlines each box on the captured image, its label above its corner" do
    {_markers, _array, overlay} =
      publish([
        detection("person", %{x0: 0.0, y0: 10.0, x1: 10.0, y1: 20.0}),
        detection("car", %{x0: 20.0, y0: 5.0, x1: 30.0, y1: 15.0})
      ])

    assert [person, car] = overlay.points

    assert Enum.map(person.points, &{&1.x, &1.y}) == [
             {0.0, 20.0},
             {20.0, 20.0},
             {20.0, 40.0},
             {0.0, 40.0}
           ]

    assert length(car.points) == 4
    assert [%{position: %{x: +0.0, y: 16.0}}, %{position: %{x: 40.0, y: 10.0}}] = overlay.texts
  end
end

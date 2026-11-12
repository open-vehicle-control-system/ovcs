defmodule VisionApiWeb.DetectionChannelTest do
  use VisionApiWeb.ChannelCase, async: false

  alias VisionCore.Camera.Frame
  alias VisionCore.Pipelines
  alias VisionCore.Detection.Live
  alias VisionCore.Stereo.Pair

  defp join(topic \\ "detections") do
    VisionApiWeb.DashboardSocket
    |> socket()
    |> subscribe_and_join(VisionApiWeb.DetectionChannel, topic)
  end

  defp pair do
    frame = %Frame{label: "left", width: 480, height: 270, capture_ns: 0, grey: <<>>}
    %Pair{left_frame: frame, right_frame: frame, geometry: %{width: 480, height: 270}}
  end

  test "pushes each detection result, with its objects' outlines on the left image" do
    start_supervised!(VisionCore.Outputs)
    start_supervised!({Live, max_hz: 1_000})
    {:ok, _reply, _socket} = join()

    # As the detection pipeline places it, its outline in the left frame's pixels.
    outline = [{120.0, 54.0}, {360.0, 54.0}, {360.0, 216.0}, {120.0, 216.0}]

    GenServer.cast(
      Live,
      {:detections, {pair(), [%{label: "person", score: 0.6, z: 1.8, outline: outline}]}}
    )

    assert_push "detections", %{detections: [detection]}
    assert %{label: "person", score: 0.6, distanceM: 1.8, outline: [[0.25, 0.2] | _]} = detection
  end

  test "joining without detection running is refused as unavailable" do
    assert {:error, %{reason: "unavailable"}} = join()
  end

  describe "a named pipeline" do
    @moduletag :capture_log

    setup do
      VisionApiWeb.TestUnit.start(%VisionCore.Config{
        components: [
          {:detector, backend: VisionCore.Detection.Backend.Stub, max_hz: 1_000},
          {:detector,
           name: :road_signs, backend: VisionCore.Detection.Backend.Stub, max_hz: 1_000}
        ]
      })
    end

    test "pushes its results on detections:<name> only, the default's on detections only" do
      {:ok, _reply, _socket} = join()
      {:ok, _reply, _socket} = join("detections:road_signs")

      outline = [{120.0, 54.0}, {360.0, 54.0}, {360.0, 216.0}, {120.0, 216.0}]
      person = %{label: "person", score: 0.6, z: 1.8, outline: outline}
      stop = %{label: "stop", score: 0.9, z: 4.0, outline: outline}
      GenServer.cast(Live, {:detections, {pair(), [person]}})

      GenServer.cast(
        Pipelines.server(Live, :road_signs),
        {{:detections, :road_signs}, {pair(), [stop]}}
      )

      assert_push "detections", %{detections: [%{label: "person"}]}
      assert_push "detections", %{detections: [%{label: "stop"}]}
      refute_push "detections", _
    end

    test "refuses an invalid or reserved name as unavailable" do
      for name <- ["Bad", "road signs", "", "stereo", "detection"] do
        assert {:error, %{reason: "unavailable"}} = join("detections:" <> name)
      end
    end

    test "refuses an existing atom that names no configured pipeline, even while its channel runs" do
      start_supervised!({Live, name: :unlisted, max_hz: 1_000})

      assert {:error, %{reason: "unavailable"}} = join("detections:unlisted")
    end

    test "refuses a name that is not an existing atom without creating one" do
      name = "no_such_pipeline_" <> Integer.to_string(System.unique_integer([:positive]))

      assert {:error, %{reason: "unavailable"}} = join("detections:" <> name)
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end
  end

  test "refuses a named pipeline on a unit that runs none as unavailable" do
    assert {:error, %{reason: "unavailable"}} = join("detections:road_signs")
  end
end

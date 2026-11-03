defmodule VisionCore.Ros2.Services.SetCameraInfoServerTest do
  use ExUnit.Case, async: true

  alias Ros2Zenoh.BuiltinInterfaces.Msg.Time
  alias Ros2Zenoh.SensorMsgs.Msg.CameraInfo
  alias Ros2Zenoh.StdMsgs.Msg.Header
  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Ros2.Services.SetCameraInfoServer

  @moduletag :tmp_dir
  @moduletag :capture_log
  @calibration Path.expand("../../../support/calibration", __DIR__)

  # The stereo unit's reload, as the server calls it: it tells the test, then answers as it is told.
  defmodule Reload do
    def answer(test, :raise) do
      send(test, :reloaded)
      raise "the calibration does not fit the frames"
    end

    def answer(test, answer) do
      send(test, :reloaded)
      answer
    end
  end

  defp start_server(tmp_dir, service_name, reload) do
    server =
      start_supervised!(
        {SetCameraInfoServer,
         service_name: service_name,
         calibration_path: Path.join(tmp_dir, "stereo_left.yaml"),
         reload: reload,
         register_service: fn _name, _module, _handler -> :ok end},
        id: service_name
      )

    :ok = SetCameraInfoServer.notify(server, self())
    server
  end

  # A sensor_msgs/SetCameraInfo request as the client hands it to the service: the CDR body.
  defp commit(server) do
    saved = CameraCalibration.load!(Path.join(@calibration, "distorted_left.yaml"))

    camera_info = %CameraInfo{
      header: %Header{stamp: %Time{}, frame_id: "stereo_left"},
      width: saved.width,
      height: saved.height,
      distortion_model: saved.distortion_model,
      d: saved.distortion_coefficients,
      k: saved.camera_matrix,
      r: saved.rectification_matrix,
      p: saved.projection_matrix
    }

    send(
      server,
      {:service_request,
       %{query: %Zenohex.Query{}, request_payload: CameraInfo.encode(camera_info)}}
    )

    :sys.get_state(server)
  end

  test "tells the process notified once the stereo unit has taken the calibration it wrote",
       %{tmp_dir: tmp_dir} do
    server = start_server(tmp_dir, "ok/set_camera_info", {Reload, :answer, [self(), :ok]})

    commit(server)

    assert File.exists?(Path.join(tmp_dir, "stereo_left.yaml"))
    assert_received :reloaded
    assert_received {:calibration_committed, "ok/set_camera_info"}
  end

  test "tells the process notified of a calibration written with no reload to make",
       %{tmp_dir: tmp_dir} do
    server = start_server(tmp_dir, "none/set_camera_info", nil)

    commit(server)

    assert_received {:calibration_committed, "none/set_camera_info"}
  end

  test "tells no one of a calibration the stereo unit refused", %{tmp_dir: tmp_dir} do
    for {service_name, answer} <- [
          {"refused/set_camera_info", {:error, :bad_calibration}},
          {"raised/set_camera_info", :raise}
        ] do
      server = start_server(tmp_dir, service_name, {Reload, :answer, [self(), answer]})

      commit(server)

      assert_received :reloaded
      refute_received {:calibration_committed, _service_name}
    end
  end
end

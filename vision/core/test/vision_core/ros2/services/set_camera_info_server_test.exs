defmodule VisionCore.Ros2.Services.SetCameraInfoServerTest do
  use ExUnit.Case, async: true

  alias Ros2Zenoh.BuiltinInterfaces.Msg.Time
  alias Ros2Zenoh.SensorMsgs.Msg.CameraInfo
  alias Ros2Zenoh.StdMsgs.Msg.Header
  alias VisionCore.Outputs
  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Ros2.Services.SetCameraInfoServer
  alias VisionCore.Stereo.Calibration

  @moduletag :tmp_dir
  @moduletag :capture_log
  @calibration Path.expand("../../../support/calibration", __DIR__)

  # Names the cameras, which need not be running.
  defmodule Camera do
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  # The stereo unit's reload, as the calibration store calls it: it tells the test, then
  # answers as it is told.
  defp reload(test, :raise) do
    fn _paths ->
      send(test, :reloaded)
      raise "the calibration does not fit the frames"
    end
  end

  defp reload(test, answer) do
    fn _paths ->
      send(test, :reloaded)
      answer
    end
  end

  # A stereo unit without a store, its calibrations in `calibration_dir`, its own prefix.
  defp config(calibration_dir, prefix) do
    %VisionCore.Config{
      components: [
        stereo: [
          driver: Camera,
          prefix: prefix,
          calibration_dir: calibration_dir,
          left: [],
          right: []
        ]
      ]
    }
  end

  defp start_server(calibration_dir, service_name, answer) do
    test = self()
    prefix = String.replace(service_name, "/", "_")
    :ok = Outputs.subscribe(Calibration.changed_key(prefix))

    start_supervised!(
      {SetCameraInfoServer,
       service_name: service_name,
       side: :left,
       config: config(calibration_dir, prefix),
       commit_options: [pipeline_running?: fn -> true end, reload: reload(test, answer)],
       register_service: fn _name, _module, _handler -> :ok end,
       respond: fn name, _query, payload ->
         send(test, {:responded, name, response(payload)})
       end},
      id: service_name
    )
  end

  defp calibration_path(tmp_dir, service_name),
    do: Path.join(tmp_dir, "#{String.replace(service_name, "/", "_")}_left.yaml")

  # The success and status message of a sensor_msgs/SetCameraInfo response, CDR-encoded.
  defp response(
         <<success, _padding::binary-size(3), size::little-32, message::binary-size(size - 1), 0,
           _string_padding::binary>>
       ),
       do: {success == 1, message}

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

  test "answers success once the stereo unit has taken the calibration it wrote, and tells the change",
       %{tmp_dir: tmp_dir} do
    server = start_server(tmp_dir, "ok/set_camera_info", :ok)

    commit(server)

    assert File.read!(calibration_path(tmp_dir, "ok/set_camera_info")) =~
             "camera_name: ok_set_camera_info_left"

    assert_received :reloaded
    assert_received {:"$gen_cast", {:stereo_calibration_changed, "ok_set_camera_info"}}
    assert_received {:responded, "ok/set_camera_info", {true, "ok"}}
  end

  test "tells no one of a calibration the stereo unit refused", %{tmp_dir: tmp_dir} do
    for {service_name, answer} <- [
          {"refused/set_camera_info", {:error, :bad_calibration}},
          {"raised/set_camera_info", :raise}
        ] do
      server = start_server(tmp_dir, service_name, answer)

      commit(server)

      assert_received :reloaded
      refute_received {:"$gen_cast", {:stereo_calibration_changed, _prefix}}
    end
  end

  test "puts back the calibration it replaced when the stereo unit refuses the new one, and answers why",
       %{tmp_dir: tmp_dir} do
    path = calibration_path(tmp_dir, "replaced/set_camera_info")
    File.write!(path, "the calibration in use")

    server = start_server(tmp_dir, "replaced/set_camera_info", {:error, :bad_calibration})

    commit(server)

    assert File.read!(path) == "the calibration in use"
    assert_received {:responded, "replaced/set_camera_info", {false, message}}
    assert message =~ "bad_calibration"
  end

  test "commits nothing over a calibration it cannot read, and answers why", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(calibration_path(tmp_dir, "unreadable/set_camera_info"))

    server = start_server(tmp_dir, "unreadable/set_camera_info", :ok)

    commit(server)

    refute_received :reloaded
    assert_received {:responded, "unreadable/set_camera_info", {false, message}}
    assert message =~ "cannot read the calibration it would replace"
  end

  test "answers why without a calibration path to write" do
    server = start_server(nil, "nowhere/set_camera_info", :ok)

    commit(server)

    refute_received :reloaded
    assert_received {:responded, "nowhere/set_camera_info", {false, message}}
    assert message =~ "no calibration path to write"
  end

  test "removes the calibration it wrote when the stereo unit refuses it and none was there",
       %{tmp_dir: tmp_dir} do
    for {service_name, answer} <- [
          {"refused/set_camera_info", {:error, :bad_calibration}},
          {"raised/set_camera_info", :raise}
        ] do
      server = start_server(tmp_dir, service_name, answer)

      commit(server)

      refute File.exists?(calibration_path(tmp_dir, service_name))
      assert_received {:responded, ^service_name, {false, _message}}
    end
  end
end

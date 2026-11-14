defmodule VisionCore.Ros2.Services.SetCameraInfoServerTest do
  use ExUnit.Case, async: true

  alias Ros2Zenoh.BuiltinInterfaces.Msg.Time
  alias Ros2Zenoh.SensorMsgs.Msg.CameraInfo
  alias Ros2Zenoh.StdMsgs.Msg.Header
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

  # A commit that tells the test what it was given, then answers as it is told.
  defp commit_answering(answer) do
    test = self()

    fn calibration ->
      send(test, {:committed, calibration})
      if answer == :raise, do: raise("the unit is gone"), else: answer
    end
  end

  defp start_server(service_name, commit) do
    test = self()

    start_supervised!(
      {SetCameraInfoServer,
       service_name: service_name,
       commit: commit,
       register_service: fn _name, _module, _handler -> :ok end,
       respond: fn name, _query, payload ->
         send(test, {:responded, name, response(payload)})
       end},
      id: service_name
    )
  end

  # The success and status message of a sensor_msgs/SetCameraInfo response, CDR-encoded.
  defp response(
         <<success, _padding::binary-size(3), size::little-32, message::binary-size(size - 1), 0,
           _string_padding::binary>>
       ),
       do: {success == 1, message}

  defp camera_info do
    saved = CameraCalibration.load!(Path.join(@calibration, "distorted_left.yaml"))

    %CameraInfo{
      header: %Header{stamp: %Time{}, frame_id: "stereo_left"},
      width: saved.width,
      height: saved.height,
      distortion_model: saved.distortion_model,
      d: saved.distortion_coefficients,
      k: saved.camera_matrix,
      r: saved.rectification_matrix,
      p: saved.projection_matrix
    }
  end

  defp commit(server, camera_info \\ camera_info()),
    do: request(server, CameraInfo.encode(camera_info))

  # A sensor_msgs/SetCameraInfo request as the client hands it to the service: the CDR body.
  defp request(server, payload) do
    send(server, {:service_request, %{query: %Zenohex.Query{}, request_payload: payload}})
    :sys.get_state(server)
  end

  test "commits the calibration of the camera info it is sent, and answers ok" do
    server = start_server("ok/set_camera_info", commit_answering(:ok))

    commit(server)

    assert_received {:committed, calibration}
    assert calibration == CameraCalibration.load!(Path.join(@calibration, "distorted_left.yaml"))
    assert_received {:responded, "ok/set_camera_info", {true, "ok"}}
  end

  test "answers why a commit is refused, or fails" do
    for {service_name, answer, reason} <- [
          {"refused/set_camera_info", {:error, "the stereo unit refused the calibration"},
           "the stereo unit refused the calibration"},
          {"missing/set_camera_info", {:error, :not_found}, ":not_found"},
          {"raised/set_camera_info", :raise, "the unit is gone"}
        ] do
      server = start_server(service_name, commit_answering(answer))

      commit(server)

      assert_received {:responded, ^service_name, {false, message}}
      assert message =~ reason
      assert Process.alive?(server)
    end
  end

  test "writes a stereo side through the stereo unit's calibration, one file renamed over the other",
       %{tmp_dir: tmp_dir} do
    prefix = "service_#{System.unique_integer([:positive])}"

    config = %VisionCore.Config{
      components: [
        stereo: [
          driver: Camera,
          prefix: prefix,
          calibration_store_dir: tmp_dir,
          left: [],
          right: []
        ]
      ]
    }

    path = Path.join(tmp_dir, "#{prefix}_left.yaml")
    File.write!(path, "the calibration stored")
    File.mkdir_p!(path <> ".tmp")
    server = start_server("side/set_camera_info", &Calibration.commit_side(config, :left, &1))

    commit(server)

    assert_received {:responded, "side/set_camera_info", {false, message}}
    assert message =~ "write failed"
    assert File.read!(path) == "the calibration stored"

    File.rmdir!(path <> ".tmp")
    commit(server)

    assert_received {:responded, "side/set_camera_info", {true, "ok"}}
    assert File.read!(path) =~ "camera_name: #{prefix}_left"
    refute File.exists?(path <> ".tmp")
  end

  test "answers a request it cannot decode as failed, and keeps running" do
    server = start_server("malformed/set_camera_info", commit_answering(:ok))
    whole = CameraInfo.encode(camera_info())

    for payload <- [nil, <<>>, <<1, 2, 3>>, binary_part(whole, 0, div(byte_size(whole), 2))] do
      request(server, payload)

      assert_received {:responded, "malformed/set_camera_info",
                       {false, "could not decode the request"}}
    end

    refute_received {:committed, _calibration}
    assert Process.alive?(server)
  end

  test "refuses a camera info that is no calibration, and commits nothing" do
    server = start_server("junk/set_camera_info", commit_answering(:ok))
    good = camera_info()

    for {junk, reason} <- [
          {%CameraInfo{header: good.header}, "its image has no size"},
          {%{good | width: 0}, "its image has no size"},
          {%{good | height: 0}, "its image has no size"},
          {%{good | d: [0.1]}, "it has 1 distortion coefficients, not the 5 of plumb_bob"},
          {%{good | k: List.replace_at(good.k, 0, 0.0)}, "its focal lengths are not positive"}
        ] do
      commit(server, junk)

      assert_received {:responded, "junk/set_camera_info", {false, message}}
      assert message == "not a calibration: " <> reason
    end

    refute_received {:committed, _calibration}
  end

  test "refuses a camera info whose matrix lost a value on the wire" do
    server = start_server("nan/set_camera_info", commit_answering(:ok))
    not_a_number = <<0, 0, 0, 0, 0, 0, 0xF8, 0x7F>>
    good = camera_info()
    whole = CameraInfo.encode(good)
    first_focal = <<hd(good.k)::little-float-64>>
    {offset, 8} = :binary.match(whole, first_focal)

    request(
      server,
      binary_part(whole, 0, offset) <>
        not_a_number <> binary_part(whole, offset + 8, byte_size(whole) - offset - 8)
    )

    assert_received {:responded, "nan/set_camera_info", {false, message}}
    assert message == "not a calibration: its camera matrix has 8 values, not 9"
    refute_received {:committed, _calibration}
  end

  test "ignores a message that is no request" do
    server = start_server("stray/set_camera_info", commit_answering(:ok))

    send(server, :stray)

    assert :sys.get_state(server)
  end
end

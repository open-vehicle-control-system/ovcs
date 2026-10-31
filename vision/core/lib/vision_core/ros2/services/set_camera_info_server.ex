defmodule VisionCore.Ros2.Services.SetCameraInfoServer do
  @moduledoc """
  ROS 2 service server for `sensor_msgs/srv/SetCameraInfo`. One
  instance per camera side; together they make the
  `cameracalibrator` GUI's **COMMIT** button work — clicking it
  delivers the freshly-solved `CameraInfo` over Zenoh, this persists
  it to the side's YAML and triggers a hot-reload of the stereo
  pipeline so the new geometry takes effect on the next frame.

  ## Required opts

    * `:service_name` — full ROS service name (e.g.
      `"/stereo/left/set_camera_info"`).
    * `:calibration_path` — destination YAML on disk
      (e.g. `priv/calibration/stereo_left.yaml` in the vehicle package);
      its directory is created if missing.
    * `:camera_name` — `camera_name:` field written into the
      YAML; informational only.
    * `:reload` — `{module, function, args}` invoked with no extra
      args after a successful write. Lets the calling
      supervisor wire in the stereo pipeline's reload without
      coupling this module to it.
  """
  use GenServer
  require Logger

  alias VisionCore.Ros2.CameraCalibration
  alias Ros2Zenoh.SensorMsgs.Srv.SetCameraInfo
  alias Ros2Zenoh.SensorMsgs.Srv.SetCameraInfo.{Request, Response}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: name_for(Keyword.fetch!(opts, :service_name)))
  end

  def name_for(service_name) do
    Module.concat([__MODULE__, "S_#{service_name}"])
  end

  @impl GenServer
  def init(opts) do
    service_name = Keyword.fetch!(opts, :service_name)
    calibration_path = Keyword.fetch!(opts, :calibration_path)
    camera_name = Keyword.get(opts, :camera_name, Path.basename(calibration_path, ".yaml"))
    reload = Keyword.get(opts, :reload)

    VisionCore.Ros2.ZenohClient.register_service(service_name, SetCameraInfo, self())

    Logger.info("#{__MODULE__} ready for #{service_name} → #{calibration_path}")

    {:ok,
     %{
       service_name: service_name,
       calibration_path: calibration_path,
       camera_name: camera_name,
       reload: reload
     }}
  end

  @impl GenServer
  def handle_info({:service_request, %{query: query, request_payload: payload}}, state) do
    response =
      case Request.parse(payload) do
        {:ok, %Request{camera_info: camera_info}, _rest} ->
          persist_calibration(camera_info, state)

        error ->
          Logger.warning(
            "#{__MODULE__}[#{state.service_name}] could not parse request: " <> inspect(error)
          )

          %Response{success: false, status_message: "could not decode request"}
      end

    VisionCore.Ros2.ZenohClient.respond(state.service_name, query, Response.encode(response))
    {:noreply, state}
  end

  defp persist_calibration(camera_info, state) do
    calibration = CameraCalibration.from_camera_info(camera_info)
    yaml = CameraCalibration.to_yaml(calibration, state.camera_name)

    with :ok <- File.mkdir_p(Path.dirname(state.calibration_path)),
         :ok <- File.write(state.calibration_path, yaml) do
      Logger.info(
        "#{__MODULE__}[#{state.service_name}] wrote " <>
          "#{byte_size(yaml)} B → #{state.calibration_path}"
      )

      maybe_reload(state.reload)
      %Response{success: true, status_message: "ok"}
    else
      {:error, reason} ->
        Logger.warning("#{__MODULE__}[#{state.service_name}] write failed: #{inspect(reason)}")

        %Response{success: false, status_message: "write failed: #{inspect(reason)}"}
    end
  end

  defp maybe_reload(nil), do: :ok

  defp maybe_reload({module, function, args}) do
    apply(module, function, args)
  catch
    kind, reason ->
      Logger.warning("#{__MODULE__}: reload callback failed #{kind}: #{inspect(reason)}")
  end
end

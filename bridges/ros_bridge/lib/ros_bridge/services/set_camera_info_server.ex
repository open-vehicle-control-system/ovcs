defmodule RosBridge.Services.SetCameraInfoServer do
  @moduledoc """
  ROS 2 service server for `sensor_msgs/srv/SetCameraInfo`. One
  instance per camera side; together they make the
  `cameracalibrator` GUI's **COMMIT** button work — clicking it
  delivers the freshly-solved `CameraInfo` over Zenoh, we persist
  it to the side's YAML, and trigger a hot-reload of the SGBM
  backend so the new geometry takes effect on the next frame.

  ## Required opts

    * `:service_name` — full ROS service name (e.g.
      `"/stereo/left/set_camera_info"`).
    * `:calibration_path` — destination YAML on disk
      (e.g. `vehicles/ovcs_mini/priv/calibration/stereo_left.yaml`).
    * `:camera_name` — `camera_name:` field written into the
      YAML; informational only.
    * `:reload` — `{module, function, args}` invoked with no extra
      args after a successful write. Lets the calling
      supervisor wire in the stereo backend's reload without
      coupling this module to it.
  """
  use GenServer
  require Logger

  alias RosBridge.Camera.Calibration
  alias Ros2.SensorMsgs.Srv.SetCameraInfo
  alias Ros2.SensorMsgs.Srv.SetCameraInfo.Request
  alias Ros2.SensorMsgs.Srv.SetCameraInfo.Response

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: name_for(Keyword.fetch!(opts, :service_name)))
  end

  def name_for(service_name) do
    Module.concat([__MODULE__, "S_#{service_name}"])
  end

  @impl true
  def init(opts) do
    service_name = Keyword.fetch!(opts, :service_name)
    calibration_path = Keyword.fetch!(opts, :calibration_path)
    camera_name = Keyword.get(opts, :camera_name, Path.basename(calibration_path, ".yaml"))
    reload = Keyword.get(opts, :reload)

    RosBridge.ZenohClient.register_service(service_name, SetCameraInfo, self())

    Logger.info("#{__MODULE__} ready for #{service_name} → #{calibration_path}")

    {:ok,
     %{
       service_name: service_name,
       calibration_path: calibration_path,
       camera_name: camera_name,
       reload: reload
     }}
  end

  @impl true
  def handle_info({:service_request, %{query: query, request_payload: payload}}, state) do
    response =
      case Request.parse(payload) do
        {:ok, %Request{camera_info: camera_info}, _rest} ->
          handle_request(camera_info, state)

        error ->
          Logger.warning(
            "#{__MODULE__}[#{state.service_name}] could not parse request: " <> inspect(error)
          )

          %Response{success: false, status_message: "could not decode request"}
      end

    RosBridge.ZenohClient.respond(state.service_name, query, Response.encode(response))
    {:noreply, state}
  end

  defp handle_request(camera_info, state) do
    calibration = Calibration.from_camera_info(camera_info)
    yaml = Calibration.to_yaml(calibration, state.camera_name)

    case File.write(state.calibration_path, yaml) do
      :ok ->
        Logger.info(
          "#{__MODULE__}[#{state.service_name}] wrote " <>
            "#{byte_size(yaml)} B → #{state.calibration_path}"
        )

        maybe_reload(state.reload)
        %Response{success: true, status_message: "ok"}

      {:error, reason} ->
        Logger.warning(
          "#{__MODULE__}[#{state.service_name}] write failed: #{inspect(reason)}"
        )

        %Response{success: false, status_message: "write failed: #{inspect(reason)}"}
    end
  end

  defp maybe_reload(nil), do: :ok

  defp maybe_reload({module, function, args}) do
    try do
      apply(module, function, args)
    catch
      kind, reason ->
        Logger.warning("#{__MODULE__}: reload callback failed #{kind}: #{inspect(reason)}")
    end
  end
end

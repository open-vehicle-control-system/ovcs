defmodule VisionCore.Ros2.Services.SetCameraInfoServer do
  @moduledoc """
  ROS 2 service server for `sensor_msgs/srv/SetCameraInfo`. One
  instance per stereo side and per camera of its own; they make the
  `cameracalibrator` GUI's **COMMIT** button work: clicking it delivers
  the solved `CameraInfo` over Zenoh, and this commits it as the
  camera's calibration, through its `:commit`.

  A request that does not decode, a `CameraInfo` that is no calibration
  (`VisionCore.Ros2.CameraCalibration.check/1`, or an image without a
  size) and a commit that is refused, raises or exits are each answered
  `success: false` with the reason; none stops the server.
  `VisionCore.Ros2.Exporter` starts one per side and camera it
  publishes, as a helper.

  ## Options

    * `:service_name` — the full ROS service name, as
      `"/stereo/left/set_camera_info"` (required).
    * `:commit` — commits a `VisionCore.Ros2.CameraCalibration`, answering
      `:ok` or `{:error, reason}` (required), as
      `VisionCore.Stereo.Calibration.commit_side/4` for a stereo side and
      `VisionCore.Camera.Calibration.commit/3` for a camera of its own.
    * `:register_service` (`&Ros2Zenoh.Client.register_service/3`)
      — registers the service, called with its name, its module and
      this server's pid.
    * `:respond` (`&Ros2Zenoh.Client.respond/3`) — answers a
      request, called with the service name, the query and the encoded
      response.
  """
  use GenServer
  require Logger

  alias Ros2Zenoh.SensorMsgs.Srv.SetCameraInfo
  alias Ros2Zenoh.SensorMsgs.Srv.SetCameraInfo.{Request, Response}
  alias VisionCore.Ros2.CameraCalibration

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: name_for(Keyword.fetch!(opts, :service_name)))
  end

  def name_for(service_name) do
    Module.concat([__MODULE__, "S_#{service_name}"])
  end

  @impl GenServer
  def init(opts) do
    service_name = Keyword.fetch!(opts, :service_name)
    register_service = Keyword.get(opts, :register_service, &Ros2Zenoh.Client.register_service/3)

    register_service.(service_name, SetCameraInfo, self())
    Logger.info("#{__MODULE__} ready for #{service_name}")

    {:ok,
     %{
       service_name: service_name,
       commit: Keyword.fetch!(opts, :commit),
       respond: Keyword.get(opts, :respond, &Ros2Zenoh.Client.respond/3)
     }}
  end

  @impl GenServer
  def handle_info({:service_request, %{query: query, request_payload: payload}}, state) do
    response =
      with {:ok, camera_info} <- decode(payload),
           {:ok, calibration} <- calibration(camera_info),
           :ok <- commit(state.commit, calibration) do
        %Response{success: true, status_message: "ok"}
      else
        {:error, message} ->
          Logger.warning("#{__MODULE__}[#{state.service_name}] #{message}")
          %Response{success: false, status_message: message}
      end

    state.respond.(state.service_name, query, Response.encode(response))
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The message parsers raise on a short or missing payload.
  defp decode(payload) do
    case Request.parse(payload) do
      {:ok, %Request{camera_info: camera_info}, _rest} -> {:ok, camera_info}
      _malformed -> {:error, "could not decode the request"}
    end
  rescue
    _exception -> {:error, "could not decode the request"}
  end

  defp calibration(%{width: width, height: height}) when width == 0 or height == 0,
    do: {:error, "not a calibration: its image has no size"}

  defp calibration(camera_info) do
    calibration = CameraCalibration.from_camera_info(camera_info)

    case CameraCalibration.check(calibration) do
      :ok -> {:ok, calibration}
      {:error, message} -> {:error, "not a calibration: " <> message}
    end
  end

  # A commit that raises or exits is answered too: the client waits for its response.
  defp commit(commit, calibration) do
    case commit.(calibration) do
      :ok -> :ok
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "not committed: #{inspect(reason)}"}
    end
  catch
    kind, reason -> {:error, "not committed: " <> Exception.format_banner(kind, reason)}
  end
end

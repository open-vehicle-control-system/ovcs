defmodule VisionCore.Ros2.Services.SetCameraInfoServer do
  @moduledoc """
  ROS 2 service server for `sensor_msgs/srv/SetCameraInfo`. One
  instance per camera side; together they make the
  `cameracalibrator` GUI's **COMMIT** button work — clicking it
  delivers the freshly-solved `CameraInfo` over Zenoh, and this commits
  it through `VisionCore.Stereo.Calibration.commit_side/4`, which writes
  the side's YAML and has the stereo unit reload it, so the new geometry
  takes effect on the next frame. A calibration the stereo unit refuses
  is taken back, and the answer is `success: false` with the reason.
  `VisionCore.Ros2.Exporter` starts one per side it publishes, as a
  helper.

  ## Required opts

    * `:service_name` — full ROS service name (e.g.
      `"/stereo/left/set_camera_info"`).
    * `:side` — `:left` or `:right`, the camera it calibrates.
    * `:config` — the `VisionCore.Config` whose stereo unit it calibrates.

  ## Optional opts

    * `:commit_options` (`[]`) — the options given to
      `VisionCore.Stereo.Calibration.commit_side/4`.
    * `:register_service` (`&Ros2Zenoh.Client.register_service/3`)
      — registers the service, called with its name, its module and
      this server's pid.
    * `:respond` (`&Ros2Zenoh.Client.respond/3`) — answers a
      request, called with the service name, the query and the encoded
      response.
  """
  use GenServer
  require Logger

  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Stereo.Calibration
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
    side = Keyword.fetch!(opts, :side)
    register_service = Keyword.get(opts, :register_service, &Ros2Zenoh.Client.register_service/3)

    register_service.(service_name, SetCameraInfo, self())

    Logger.info("#{__MODULE__} ready for #{service_name}, the #{side} camera")

    {:ok,
     %{
       service_name: service_name,
       side: side,
       config: Keyword.fetch!(opts, :config),
       commit_options: Keyword.get(opts, :commit_options, []),
       respond: Keyword.get(opts, :respond, &Ros2Zenoh.Client.respond/3)
     }}
  end

  @impl GenServer
  def handle_info({:service_request, %{query: query, request_payload: payload}}, state) do
    response =
      case Request.parse(payload) do
        {:ok, %Request{camera_info: camera_info}, _rest} ->
          commit(camera_info, state)

        error ->
          Logger.warning(
            "#{__MODULE__}[#{state.service_name}] could not parse request: " <> inspect(error)
          )

          %Response{success: false, status_message: "could not decode request"}
      end

    state.respond.(state.service_name, query, Response.encode(response))
    {:noreply, state}
  end

  defp commit(camera_info, state) do
    calibration = CameraCalibration.from_camera_info(camera_info)

    case Calibration.commit_side(state.config, state.side, calibration, state.commit_options) do
      :ok ->
        %Response{success: true, status_message: "ok"}

      {:error, message} ->
        %Response{success: false, status_message: message}
    end
  end
end

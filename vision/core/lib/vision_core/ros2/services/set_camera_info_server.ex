defmodule VisionCore.Ros2.Services.SetCameraInfoServer do
  @moduledoc """
  ROS 2 service server for `sensor_msgs/srv/SetCameraInfo`. One
  instance per camera side; together they make the
  `cameracalibrator` GUI's **COMMIT** button work — clicking it
  delivers the freshly-solved `CameraInfo` over Zenoh, this persists
  it to the side's YAML and triggers a hot-reload of the stereo
  pipeline so the new geometry takes effect on the next frame.
  `VisionCore.Ros2.Exporter` starts one per side it publishes, as a
  helper, and is told of each calibration committed (`notify/2`).

  ## Required opts

    * `:service_name` — full ROS service name (e.g.
      `"/stereo/left/set_camera_info"`).
    * `:calibration_path` — destination YAML on disk
      (e.g. `priv/calibration/stereo_left.yaml` in the vehicle package);
      its directory is created if missing.
    * `:camera_name` — `camera_name:` field written into the
      YAML; informational only.
    * `:reload` — `{module, function, args}` invoked with no extra
      args after a successful write, answering `:ok` once the stereo
      unit has taken the calibration. Lets the calling
      supervisor wire in the stereo pipeline's reload without
      coupling this module to it.
    * `:register_service` (`&VisionCore.Ros2.ZenohClient.register_service/3`)
      — registers the service, called with its name, its module and
      this server's pid.
  """
  use GenServer
  require Logger

  alias VisionCore.Ros2.{CameraCalibration, ZenohClient}
  alias Ros2Zenoh.SensorMsgs.Srv.SetCameraInfo
  alias Ros2Zenoh.SensorMsgs.Srv.SetCameraInfo.{Request, Response}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: name_for(Keyword.fetch!(opts, :service_name)))
  end

  def name_for(service_name) do
    Module.concat([__MODULE__, "S_#{service_name}"])
  end

  @doc """
  Has `server` send `pid` `{:calibration_committed, service_name}` after
  each calibration it writes and the stereo unit takes, its `:reload`
  answering `:ok`, or with no `:reload`; in place of the pid it told
  before. A calibration the reload refuses, or raises on, is not told.
  """
  @spec notify(GenServer.server(), pid()) :: :ok
  def notify(server, pid), do: GenServer.cast(server, {:notify, pid})

  @impl GenServer
  def init(opts) do
    service_name = Keyword.fetch!(opts, :service_name)
    calibration_path = Keyword.fetch!(opts, :calibration_path)
    camera_name = Keyword.get(opts, :camera_name, Path.basename(calibration_path, ".yaml"))
    reload = Keyword.get(opts, :reload)
    register_service = Keyword.get(opts, :register_service, &ZenohClient.register_service/3)

    register_service.(service_name, SetCameraInfo, self())

    Logger.info("#{__MODULE__} ready for #{service_name} → #{calibration_path}")

    {:ok,
     %{
       service_name: service_name,
       calibration_path: calibration_path,
       camera_name: camera_name,
       reload: reload,
       notified: nil
     }}
  end

  @impl GenServer
  def handle_cast({:notify, pid}, state), do: {:noreply, %{state | notified: pid}}

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

    ZenohClient.respond(state.service_name, query, Response.encode(response))
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

      if reload(state) == :ok and state.notified,
        do: send(state.notified, {:calibration_committed, state.service_name})

      %Response{success: true, status_message: "ok"}
    else
      {:error, reason} ->
        Logger.warning("#{__MODULE__}[#{state.service_name}] write failed: #{inspect(reason)}")

        %Response{success: false, status_message: "write failed: #{inspect(reason)}"}
    end
  end

  defp reload(%{reload: nil}), do: :ok

  defp reload(%{reload: {module, function, args}} = state) do
    case apply(module, function, args) do
      :ok -> :ok
      refusal -> reload_failed(state, inspect(refusal))
    end
  catch
    kind, reason -> reload_failed(state, "#{kind}: #{inspect(reason)}")
  end

  defp reload_failed(state, reason) do
    Logger.warning(
      "#{__MODULE__}[#{state.service_name}] the stereo unit did not take the calibration " <>
        "written to #{state.calibration_path}: #{reason}"
    )

    {:error, reason}
  end
end

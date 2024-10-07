defmodule CvBridgex.Application do
  @moduledoc false

  require Logger

  use Application

  @impl true
  def start(_type, _args) do
    cameras = Application.get_env(:cv_bridgex, :cameras)
    cameras_processes = Enum.map(cameras, fn camera ->
      %{
        id: camera.process_name,
        start: {
          CvBridgex.CvCamera,
          :start_link, [%{process_name: camera.process_name, device: camera.device_id}]
        },
      }
    end)
    emitters_processes = Enum.map(cameras, fn camera ->
      %{
        id: camera.emitter_process_name,
        start: {
          CvBridgex.RosImageEmitter,
          :start_link, [%{process_name: camera.emitter_process_name, topic: camera.topic, camera_process_name: camera.process_name}]
        }
      }
    end)
    children = cameras_processes ++ emitters_processes
    opts = [strategy: :one_for_one, name: CvBridgex.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

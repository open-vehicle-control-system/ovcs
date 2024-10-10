defmodule RclexCam.Application do
  @moduledoc false

  require Logger

  use Application

  @impl true
  def start(_type, _args) do
    cameras = Application.get_env(:rclex_cam, :cameras)
    children = Enum.map(cameras, fn camera ->
      %{
        id: camera.process_name,
        start: {
          RclexCam.Camera,
          :start_link, [%{
            process_name: camera.process_name,
            device:       camera.device,
            topic:        camera.topic,
            frame_id:     camera.frame_id,
            props:        Map.get(camera, :props, nil)
          }]
        },
      }
    end)
    opts = [strategy: :one_for_one, name: RclexCam.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

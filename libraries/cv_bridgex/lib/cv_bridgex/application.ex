defmodule CvBridgex.Application do
  @moduledoc false

  require Logger

  use Application

  @impl true
  def start(_type, _args) do
    cameras = Application.get_env(:cv_bridgex, :cameras)
    children = Enum.map(cameras, fn camera ->
      %{
        id: camera.process_name,
        start: {
          CvBridgex.CvCamera,
          :start_link, [%{process_name: camera.process_name, device: camera.device, topic: camera.topic, props: camera.props}]
        },
      }
    end)
    opts = [strategy: :one_for_one, name: CvBridgex.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

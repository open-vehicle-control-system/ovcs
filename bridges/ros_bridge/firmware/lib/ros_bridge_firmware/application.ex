defmodule ROSBridgeFirmware.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    cameras = Application.get_env(:ros_bridge_firmware, :cameras)
    orchestrator = Application.get_env(:ros_bridge_firmware, :orchestrator)
    camera_children = Enum.map(cameras, fn camera ->
      %{
        id: camera.process_name,
        start: {
          ROSBridgeFirmware.Camera,
          :start_link, [%{
            process_name: camera.process_name,
            device:       camera.device,
            topic:        camera.topic,
            frame_id:     camera.frame_id,
            props:        Map.get(camera, :props, %{}),
            orchestrator: orchestrator,
            info:         Map.get(camera, :info, %{})
          }]
        },
      }
    end)
    teleop_child = %{
      id: ROSBridgeFirmware.Teleop,
      start: {
        ROSBridgeFirmware.Teleop,
        :start_link, [%{
          orchestrator: orchestrator
        }]
      }
    }

    children = camera_children ++ [teleop_child]

    opts = [strategy: :one_for_one, name: ROSBridgeFirmware.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

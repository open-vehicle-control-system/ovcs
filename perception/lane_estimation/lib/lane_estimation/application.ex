defmodule LaneEstimation.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    environment = Application.get_env(:lane_estimation, :config)
    image_listener_child = %{
      id: LaneEstimation.ImageListener,
      start: {
        LaneEstimation.ImageListener,
        :start_link, [%{
          input_image_topic: environment.input_image_topic,
          output_lane_topic: environment.output_lane_topic,
          node_name: environment.node_name
        }]
      }
    }
    children = [image_listener_child]
    opts = [strategy: :one_for_one, name: LaneEstimation.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

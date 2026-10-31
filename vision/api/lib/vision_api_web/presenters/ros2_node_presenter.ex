defmodule VisionApiWeb.Ros2NodePresenter do
  @moduledoc """
  The unit's ROS 2 node (`VisionCore.Ros2.ZenohClient.link/0`) as a
  `ros2-nodes` JSON:API resource, with its `ros2-topics` and
  `ros2-services`.
  """
  alias VisionApiWeb.JsonApi

  @spec present(map(), [map()]) :: map()
  def present(link, topics) do
    JsonApi.resource(
      "ros2-nodes",
      link.node_name,
      %{name: link.node_name, zenohEndpoint: link.endpoint, connected: link.connected},
      %{
        topics: JsonApi.to_many("ros2-topics", Enum.map(topics, & &1.name)),
        services: JsonApi.to_many("ros2-services", Enum.map(link.services, & &1.name))
      }
    )
  end

  @doc "A topic the node published (`VisionCore.Ros2.Topics.topics/0`)."
  @spec topic(map()) :: map()
  def topic(topic),
    do:
      JsonApi.resource("ros2-topics", topic.name, %{
        name: topic.name,
        messageType: topic.type,
        rateHz: topic.rate_hz
      })

  @doc "A service the node answers."
  @spec service(map()) :: map()
  def service(service),
    do:
      JsonApi.resource("ros2-services", service.name, %{
        name: service.name,
        serviceType: service.type
      })
end

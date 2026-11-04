defmodule VisionApiWeb.Ros2NodeJSON do
  @moduledoc """
  The unit's ROS 2 node (`VisionCore.Ros2.Node.link/0`) as a
  `ros2-nodes` JSON:API resource, with its `ros2-topics` and
  `ros2-services`.
  """
  alias VisionApiWeb.JsonApi

  @doc """
  The node of `link` (`VisionCore.Ros2.Node.link/0`), related to its
  `topics` and services, with those `includes` names, `"topics"` or
  `"services"`, in `included`.
  """
  @spec show(%{link: map(), topics: [map()], includes: [String.t()]}) :: map()
  def show(%{link: link, topics: topics, includes: []}), do: %{data: data(link, topics)}

  def show(%{link: link, topics: topics, includes: includes}) do
    included =
      Enum.flat_map(includes, fn
        "topics" -> Enum.map(topics, &topic/1)
        "services" -> Enum.map(link.services, &service/1)
      end)

    %{data: data(link, topics), included: included}
  end

  defp data(link, topics) do
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

  defp topic(topic),
    do:
      JsonApi.resource("ros2-topics", topic.name, %{
        name: topic.name,
        messageType: topic.type,
        rateHz: topic.rate_hz
      })

  defp service(service),
    do:
      JsonApi.resource("ros2-services", service.name, %{
        name: service.name,
        serviceType: service.type
      })
end

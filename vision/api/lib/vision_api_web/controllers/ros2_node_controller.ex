defmodule VisionApiWeb.Ros2NodeController do
  @moduledoc """
  The unit's ROS 2 node, a `ros2-nodes` singleton identified by its node
  name: its Zenoh endpoint and whether the session is open
  (`VisionCore.Ros2.ZenohClient.link/0`), with its `topics`, every
  `ros2-topics` it has published with its type and rate
  (`VisionCore.Ros2.Topics`), and its `services`, the `ros2-services` it
  answers. `include=topics,services`, or either alone, puts them in
  `included`.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.JsonApi
  alias VisionCore.Ros2.{Topics, ZenohClient}

  @relationships ["topics", "services"]

  def show(conn, params) do
    case includes(params) do
      {:ok, includes} ->
        send_node(conn, includes)

      :error ->
        JsonApi.error(conn, 400, "Bad Request", "unsupported include", %{parameter: "include"})
    end
  end

  defp send_node(conn, includes) do
    link = ZenohClient.link()
    topics = Enum.map(Topics.topics(), &topic/1)
    services = Enum.map(link.services, &service/1)

    node =
      JsonApi.resource(
        "ros2-nodes",
        link.node_name,
        %{name: link.node_name, zenohEndpoint: link.endpoint, connected: link.connected},
        %{topics: to_many(topics), services: to_many(services)}
      )

    included =
      Enum.flat_map(includes, fn
        "topics" -> topics
        "services" -> services
      end)

    document = if includes == [], do: %{data: node}, else: %{data: node, included: included}
    JsonApi.send_document(conn, 200, document)
  end

  defp topic(topic) do
    %{
      type: "ros2-topics",
      id: topic.name,
      attributes: %{name: topic.name, messageType: topic.type, rateHz: topic.rate_hz}
    }
  end

  defp service(service) do
    %{
      type: "ros2-services",
      id: service.name,
      attributes: %{name: service.name, serviceType: service.type}
    }
  end

  defp to_many(resources), do: %{data: Enum.map(resources, &Map.take(&1, [:type, :id]))}

  defp includes(%{"include" => include}) do
    includes = include |> String.split(",", trim: true) |> Enum.uniq()
    if Enum.all?(includes, &(&1 in @relationships)), do: {:ok, includes}, else: :error
  end

  defp includes(_params), do: {:ok, []}
end

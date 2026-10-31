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

  alias VisionApiWeb.{JsonApi, Ros2NodePresenter}
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
    topics = Topics.topics()
    node = Ros2NodePresenter.present(link, topics)

    included =
      Enum.flat_map(includes, fn
        "topics" -> Enum.map(topics, &Ros2NodePresenter.topic/1)
        "services" -> Enum.map(link.services, &Ros2NodePresenter.service/1)
      end)

    document = if includes == [], do: %{data: node}, else: %{data: node, included: included}
    JsonApi.send_document(conn, 200, document)
  end

  defp includes(%{"include" => include}) do
    includes = include |> String.split(",", trim: true) |> Enum.uniq()
    if Enum.all?(includes, &(&1 in @relationships)), do: {:ok, includes}, else: :error
  end

  defp includes(_params), do: {:ok, []}
end

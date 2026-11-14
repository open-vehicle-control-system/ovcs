defmodule VisionApiWeb.Ros2NodeController do
  @moduledoc """
  The unit's ROS 2 node, a `ros2-nodes` singleton identified by its node
  name: its Zenoh endpoint, whether the session is open, whether the
  board's clock is synchronized, before which nothing is published, and the
  publishes dropped while waiting for it (`VisionCore.Ros2.Node.link/0`),
  with its `topics`, every `ros2-topics` it has published with its type
  and rate (`VisionCore.Ros2.Topics`), and its `services`, the
  `ros2-services` it answers. `include=topics,services`, or either alone,
  puts them in `included`. A unit whose configuration has no `ros2:`
  section, the ROS 2 link, has no node: 404.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.JsonApi
  alias VisionCore.Ros2.{Node, Topics}

  @relationships ["topics", "services"]

  def show(conn, params) do
    with true <- ros2_link?(),
         {:ok, includes} <- JsonApi.includes(params, @relationships) do
      render(conn, :show, link: Node.link(), topics: Topics.topics(), includes: includes)
    else
      false ->
        JsonApi.error(conn, 404, "the unit has no ROS 2 link: no ros2: section")

      :error ->
        JsonApi.error(conn, 400, "unsupported include", source: %{parameter: "include"})
    end
  end

  defp ros2_link? do
    case VisionCore.Application.active_config() do
      %VisionCore.Config{ros2: ros2} -> ros2 != nil
      nil -> false
    end
  end
end

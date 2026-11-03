defmodule VisionApiWeb.Ros2NodeController do
  @moduledoc """
  The unit's ROS 2 node, a `ros2-nodes` singleton identified by its node
  name: its Zenoh endpoint and whether the session is open
  (`VisionCore.Ros2.ZenohClient.link/0`), with its `topics`, every
  `ros2-topics` it has published with its type and rate
  (`VisionCore.Ros2.Topics`), and its `services`, the `ros2-services` it
  answers. `include=topics,services`, or either alone, puts them in
  `included`. A unit whose configuration has no `ros2:` section, the
  ROS 2 link, has no node: 404.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.JsonApi
  alias VisionCore.Ros2.{Topics, ZenohClient}

  @relationships ["topics", "services"]

  def show(conn, params) do
    with true <- ros2_link?(),
         {:ok, includes} <- includes(params) do
      render(conn, :show, link: ZenohClient.link(), topics: Topics.topics(), includes: includes)
    else
      false ->
        JsonApi.error(conn, 404, "Not Found", "the unit has no ROS 2 link: no ros2: section")

      :error ->
        JsonApi.error(conn, 400, "Bad Request", "unsupported include", %{parameter: "include"})
    end
  end

  defp ros2_link? do
    case VisionCore.Application.active_config() do
      %VisionCore.Config{ros2: ros2} -> ros2 != nil
      nil -> false
    end
  end

  defp includes(%{"include" => include}) do
    includes = include |> String.split(",", trim: true) |> Enum.uniq()
    if Enum.all?(includes, &(&1 in @relationships)), do: {:ok, includes}, else: :error
  end

  defp includes(_params), do: {:ok, []}
end

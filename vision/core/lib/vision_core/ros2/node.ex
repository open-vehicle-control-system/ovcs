defmodule VisionCore.Ros2.Node do
  @moduledoc """
  The vision unit's ROS 2 node: the name and domain its `ros2:` section
  configures, and its link to the router through `Ros2Zenoh.Client`.
  """

  @default_node_name "ovcs_vision"
  @default_domain_id 0

  @doc """
  The node name the unit runs under with `config`: the `:node_name` of its
  `ros2:` section, else the default.
  """
  @spec configured_node_name(VisionCore.Config.t() | nil) :: String.t()
  def configured_node_name(%VisionCore.Config{ros2: ros2}), do: node_name(ros2)
  def configured_node_name(_config), do: @default_node_name

  @doc "The node name a `ros2:` section configures: its `:node_name`, else the default."
  @spec node_name(keyword() | nil) :: String.t()
  def node_name(ros2) when is_list(ros2), do: Keyword.get(ros2, :node_name) || @default_node_name
  def node_name(_ros2), do: @default_node_name

  @doc """
  The node and its link to the router (`Ros2Zenoh.Client.link/0`). When the
  client is not running, the node is the configured one, down, with no
  endpoint, no service and no synchronized clock.
  """
  @spec link() :: %{
          node_name: String.t(),
          domain_id: non_neg_integer(),
          connected: boolean(),
          endpoint: String.t() | nil,
          clock_synchronized: boolean(),
          drops_before_clock_synchronized: non_neg_integer(),
          services: [%{name: String.t(), type: String.t()}]
        }
  def link do
    Ros2Zenoh.Client.link() || down_link(VisionCore.Application.active_config())
  end

  defp down_link(config) do
    %{
      node_name: configured_node_name(config),
      domain_id: configured_domain_id(config),
      connected: false,
      endpoint: nil,
      clock_synchronized: false,
      drops_before_clock_synchronized: 0,
      services: []
    }
  end

  defp configured_domain_id(%VisionCore.Config{ros2: ros2}) when is_list(ros2),
    do: Keyword.get(ros2, :domain_id) || @default_domain_id

  defp configured_domain_id(_config), do: @default_domain_id
end

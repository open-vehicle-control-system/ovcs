defmodule Ros2.RosgraphMsgs.Msg.Clock do
  @moduledoc """
  ROS 2 `rosgraph_msgs/Clock`: a single `builtin_interfaces/Time`.

  What a simulator publishes so every node can agree on a time that
  is not the wall clock. `parse/1` only — nothing here is the
  authority on time, it only follows one.
  """
  use Ros2.Common

  alias Ros2.BuiltinInterfaces.Msg.Time

  defstruct clock: %Time{}

  # RIHS01 hash for ROS 2 Lyrical; it changes with the distro.
  @dds_type "rosgraph_msgs::msg::dds_::Clock_"
  @type_hash "RIHS01_692f7a66e93a3c83e71765d033b60349ba68023a8c689a79e48078bcb5c58564"

  def dds_type, do: @dds_type
  def type_hash, do: @type_hash

  def parse(body) when is_binary(body) do
    with {:ok, clock, rest} <- Time.parse(body) do
      {:ok, %__MODULE__{clock: clock}, rest}
    end
  end
end

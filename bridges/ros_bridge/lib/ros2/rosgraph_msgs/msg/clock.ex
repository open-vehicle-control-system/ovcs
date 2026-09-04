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

  def parse(body) when is_binary(body) do
    with {:ok, clock, rest} <- Time.parse(body) do
      {:ok, %__MODULE__{clock: clock}, rest}
    end
  end
end

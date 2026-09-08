defmodule Ros2.GeometryMsgs.Msg.Twist do
  @moduledoc """
  ROS 2 `geometry_msgs/Twist`: two nested `Vector3`s — `linear` and
  `angular` — six `float64`s, 48 bytes.

  Per REP-103, `linear.x` is forward and `angular.z` is
  counter-clockwise yaw. For a non-holonomic vehicle the other four
  components are meaningless, and a commander that sets them is
  telling you it thinks the vehicle is holonomic — which is worth
  noticing rather than silently ignoring.

  `parse/1` only; nothing here publishes a Twist. The bridge consumes
  velocity commands and emits CAN.
  """
  use Ros2.Common

  alias Ros2.GeometryMsgs.Msg.Vector3

  defstruct linear: %Vector3{}, angular: %Vector3{}

  def parse(body) when is_binary(body) do
    with {:ok, linear, rest} <- Vector3.parse(body),
         {:ok, angular, rest} <- Vector3.parse(rest) do
      {:ok, %__MODULE__{linear: linear, angular: angular}, rest}
    end
  end
end

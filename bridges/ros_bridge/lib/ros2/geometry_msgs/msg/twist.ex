defmodule Ros2.GeometryMsgs.Msg.Twist do
  @moduledoc """
  ROS 2 `geometry_msgs/Twist`: two nested `Vector3`s — `linear` and
  `angular` — six `float64`s, 48 bytes.

  Per REP-103, `linear.x` is forward and `angular.z` is
  counter-clockwise yaw. For a non-holonomic vehicle the other four
  components are meaningless, and a commander that sets them is
  telling you it thinks the vehicle is holonomic — which is worth
  noticing rather than silently ignoring.

  `parse/1` reads velocity commands, which the bridge turns into CAN;
  `encode/1` writes the twist inside `nav_msgs/Odometry`.
  """
  use Ros2.Common

  alias Ros2.GeometryMsgs.Msg.Vector3

  defstruct linear: %Vector3{}, angular: %Vector3{}

  # RIHS01 hash for ROS 2 Lyrical; it changes with the distro.
  @dds_type "geometry_msgs::msg::dds_::Twist_"
  @type_hash "RIHS01_9c45bf16fe0983d80e3cfe750d6835843d265a9a6c46bd2e609fcddde6fb8d2a"

  def dds_type, do: @dds_type
  def type_hash, do: @type_hash

  # Six float64s, no internal padding: the buffer must be 8-aligned on
  # entry and leaves 8-aligned.
  def encode(%__MODULE__{linear: linear, angular: angular}) do
    Vector3.encode(linear) <> Vector3.encode(angular)
  end

  def parse(body) when is_binary(body) do
    with {:ok, linear, rest} <- Vector3.parse(body),
         {:ok, angular, rest} <- Vector3.parse(rest) do
      {:ok, %__MODULE__{linear: linear, angular: angular}, rest}
    end
  end
end

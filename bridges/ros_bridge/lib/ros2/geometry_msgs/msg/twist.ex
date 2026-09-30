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

  # rmw_zenoh keyexpr metadata for `geometry_msgs/msg/Twist`, so a subscription declares
  # its liveliness token and shows in the ROS graph. The RIHS01 hash was
  # captured against ROS 2 Lyrical via `ros2 topic info -v`. Refresh on
  # distro bumps.
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

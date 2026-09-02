defmodule Ros2.VisionMsgs.Msg.ObjectHypothesisWithPose do
  @moduledoc """
  ROS 2 `vision_msgs/ObjectHypothesisWithPose`: an
  `ObjectHypothesis` followed by a `geometry_msgs/PoseWithCovariance`.

  Both halves are float64-bearing, so this is `append_to/2` all the
  way down — see `ObjectHypothesis` for the alignment that the
  leading string forces.
  """
  use Ros2.Common

  alias Ros2.GeometryMsgs.Msg.PoseWithCovariance
  alias Ros2.VisionMsgs.Msg.ObjectHypothesis

  defstruct hypothesis: %ObjectHypothesis{}, pose: %PoseWithCovariance{}

  @spec append_to(binary(), %__MODULE__{}) :: binary()
  def append_to(buffer, %__MODULE__{hypothesis: hypothesis, pose: pose})
      when is_binary(buffer) do
    buffer
    |> ObjectHypothesis.append_to(hypothesis)
    # The hypothesis ends on a float64, so this is already 8-aligned;
    # align_to/2 makes that a property of the code rather than of the
    # reader's memory of the struct above.
    |> align_to(8)
    |> Kernel.<>(PoseWithCovariance.encode(pose))
  end
end

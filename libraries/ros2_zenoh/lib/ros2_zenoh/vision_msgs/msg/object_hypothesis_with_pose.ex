defmodule Ros2Zenoh.VisionMsgs.Msg.ObjectHypothesisWithPose do
  @moduledoc """
  ROS 2 `vision_msgs/ObjectHypothesisWithPose`: an
  `ObjectHypothesis` followed by a `geometry_msgs/PoseWithCovariance`.

  Both halves are float64-bearing, so this is `append_to/2` all the
  way down — see `ObjectHypothesis` for the alignment that the
  leading string forces.
  """
  use Ros2Zenoh.Common

  alias Ros2Zenoh.GeometryMsgs.Msg.PoseWithCovariance
  alias Ros2Zenoh.VisionMsgs.Msg.ObjectHypothesis

  defstruct hypothesis: %ObjectHypothesis{}, pose: %PoseWithCovariance{}

  def msg_definition do
    """
    # An object hypothesis that contains pose information.
    # If you would like to define an array of ObjectHypothesisWithPose messages,
    #   please see the Detection2D or Detection3D message types.

    # The object hypothesis (ID and score).
    ObjectHypothesis hypothesis

    # The 6D pose of the object hypothesis. This pose should be
    #   defined as the pose of some fixed reference point on the object, such as
    #   the geometric center of the bounding box, the center of mass of the
    #   object or the origin of a reference mesh of the object.
    # Note that this pose is not stamped; frame information can be defined by
    #   parent messages.
    # Also note that different classes predicted for the same input data may have
    #   different predicted 6D poses.
    geometry_msgs/PoseWithCovariance pose
    """
  end

  def dependencies,
    do: [ObjectHypothesis, PoseWithCovariance]

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

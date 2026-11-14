defmodule VisionCore.Calibration.SavedPoseTest do
  use ExUnit.Case, async: true

  alias VisionCore.Calibration.SavedPose
  alias VisionCore.Camera.Pose

  @pose %Pose{
    rotation: [0.999, -0.02, 0.04, 0.02, 0.9998, 0.001, -0.04, 0.0, 0.9992],
    translation: [-0.1, 0.005, 0.002]
  }

  test "takes a pose, each element in its own column, and its error" do
    changeset =
      SavedPose.changeset(%SavedPose{}, Map.put(SavedPose.attributes(@pose), :rms_px, 0.41))

    assert changeset.valid?
    saved = Ecto.Changeset.apply_changes(changeset)
    assert {saved.r01, saved.tx, saved.rms_px} == {-0.02, -0.1, 0.41}
    assert SavedPose.to_pose(saved) == @pose
  end

  test "refuses a pose missing an element" do
    changeset = SavedPose.changeset(%SavedPose{}, %{SavedPose.attributes(@pose) | tz: nil})

    refute changeset.valid?
    assert {_message, [validation: :required]} = changeset.errors[:tz]
  end
end

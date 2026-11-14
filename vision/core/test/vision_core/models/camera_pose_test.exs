defmodule VisionCore.Models.CameraPoseTest do
  use ExUnit.Case, async: true

  alias VisionCore.Camera.Pose
  alias VisionCore.Models.CameraPose

  @pose %Pose{
    rotation: [0.999, -0.02, 0.04, 0.02, 0.9998, 0.001, -0.04, 0.0, 0.9992],
    translation: [-0.1, 0.005, 0.002]
  }

  defp attributes(overrides) do
    Map.merge(
      CameraPose.attributes(@pose),
      Map.merge(
        %{target: "center-pose", camera: "center", name: "Bench", origin: "dashboard"},
        overrides
      )
    )
  end

  test "takes a camera's pose and its error" do
    changeset = CameraPose.changeset(%CameraPose{}, attributes(%{rms_px: 0.41}))

    assert changeset.valid?
    kept = Ecto.Changeset.apply_changes(changeset)
    assert {kept.camera, kept.rms_px, kept.in_force} == {"center", 0.41, false}
    assert CameraPose.to_pose(kept) == @pose
    assert CameraPose.holds?(kept, @pose)
    refute CameraPose.holds?(kept, %{@pose | translation: [-0.1, 0.005, 0.003]})
  end

  test "refuses a pose without its camera, or a rotation or translation of another size" do
    changeset =
      CameraPose.changeset(
        %CameraPose{},
        attributes(%{camera: nil, rotation: [1.0], translation_m: [0.0, 0.0]})
      )

    refute changeset.valid?
    assert {_message, [validation: :required]} = changeset.errors[:camera]
    assert {_message, [count: 9, validation: :length] ++ _} = changeset.errors[:rotation]
    assert {_message, [count: 3, validation: :length] ++ _} = changeset.errors[:translation_m]
  end

  test "names a pose as any calibration kept" do
    changeset = CameraPose.changeset(%CameraPose{}, attributes(%{name: "   "}))

    assert {"a name has 1 to 80 characters", _validation} = changeset.errors[:name]
  end
end

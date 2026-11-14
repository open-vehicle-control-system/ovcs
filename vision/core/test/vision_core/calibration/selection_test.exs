defmodule VisionCore.Calibration.SelectionTest do
  use ExUnit.Case, async: true

  alias VisionCore.Calibration.Selection

  test "takes a target and the calibration in force for it" do
    changeset = Selection.changeset(%Selection{}, %{target: "stereo", calibration_id: 3})

    assert changeset.valid?
    assert changeset.changes == %{target: "stereo", calibration_id: 3}
  end

  test "refuses a selection without a target or a calibration" do
    changeset = Selection.changeset(%Selection{}, %{target: nil, calibration_id: nil})

    refute changeset.valid?
    assert {_message, [validation: :required]} = changeset.errors[:target]
    assert {_message, [validation: :required]} = changeset.errors[:calibration_id]
  end
end

defmodule VisionCore.Calibration.SavedCameraTest do
  use ExUnit.Case, async: true

  alias VisionCore.Calibration.SavedCamera
  alias VisionCore.Ros2.CameraCalibration

  @calibration %CameraCalibration{
    width: 728,
    height: 544,
    distortion_model: "plumb_bob",
    distortion_coefficients: [-0.478, 0.212, -0.0003, 0.0013, 0.0],
    camera_matrix: [886.3, 0.0, 364.6, 0.0, 887.3, 298.6, 0.0, 0.0, 1.0],
    rectification_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    projection_matrix: [864.8, 0.0, 396.4, -171.2, 0.0, 864.8, 292.7, 0.0, 0.0, 0.0, 1.0, 0.0]
  }

  describe "changeset/2" do
    test "takes a camera's calibration, each element in its own column, without its error" do
      {:ok, attributes} = SavedCamera.attributes("left", @calibration)
      changeset = SavedCamera.changeset(%SavedCamera{}, attributes)

      assert changeset.valid?
      camera = Ecto.Changeset.apply_changes(changeset)

      assert {camera.name, camera.fx, camera.k1, camera.p03, camera.rms_px} ==
               {"left", 886.3, -0.478, -171.2, nil}

      assert SavedCamera.to_calibration(camera) == @calibration
    end

    test "refuses a camera missing a name or an element" do
      {:ok, attributes} = SavedCamera.attributes("left", @calibration)
      changeset = SavedCamera.changeset(%SavedCamera{}, %{attributes | name: nil, fx: nil})

      refute changeset.valid?
      assert {_message, [validation: :required]} = changeset.errors[:name]
      assert {_message, [validation: :required]} = changeset.errors[:fx]
    end
  end

  test "has no columns for another distortion model" do
    rational = %{@calibration | distortion_model: "rational_polynomial"}

    assert {:error, reason} = SavedCamera.attributes("left", rational)
    assert reason =~ "plumb_bob"
  end
end

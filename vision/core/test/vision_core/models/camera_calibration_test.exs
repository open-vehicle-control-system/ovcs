defmodule VisionCore.Models.CameraCalibrationTest do
  use ExUnit.Case, async: true

  alias VisionCore.Models
  alias VisionCore.Ros2.CameraCalibration

  defp attributes(overrides) do
    {:ok, lens} =
      Models.Lens.attributes(%CameraCalibration{
        width: 728,
        height: 544,
        distortion_model: "plumb_bob",
        distortion_coefficients: [-0.478, 0.212, -0.0003, 0.0013, 0.0],
        camera_matrix: [580.8, 0.0, 364.6, 0.0, 581.8, 298.6, 0.0, 0.0, 1.0],
        rectification_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
        projection_matrix: [580.8, 0.0, 364.6, 0.0, 0.0, 581.8, 298.6, 0.0, 0.0, 0.0, 1.0, 0.0]
      })

    Map.merge(
      %{
        target: "center",
        camera: "center",
        name: "Bench",
        origin: "dashboard",
        lens: Map.put(lens, :rms_px, 0.2)
      },
      overrides
    )
  end

  test "takes a camera's calibration with its lens" do
    changeset = Models.CameraCalibration.changeset(%Models.CameraCalibration{}, attributes(%{}))

    assert changeset.valid?
    kept = Ecto.Changeset.apply_changes(changeset)

    assert {kept.camera, kept.lens.fx, kept.lens.rms_px, kept.in_force} ==
             {"center", 580.8, 0.2, false}
  end

  test "refuses a calibration without its camera or its lens" do
    changeset =
      Models.CameraCalibration.changeset(
        %Models.CameraCalibration{},
        attributes(%{camera: nil, lens: nil})
      )

    refute changeset.valid?
    assert {_message, [validation: :required]} = changeset.errors[:camera]
    assert {_message, [validation: :required]} = changeset.errors[:lens]
  end

  test "names a camera's calibration as any calibration kept" do
    changeset =
      Models.CameraCalibration.changeset(
        %Models.CameraCalibration{},
        attributes(%{name: String.duplicate("a", 81)})
      )

    assert {"a name has 1 to 80 characters", _validation} = changeset.errors[:name]
  end
end

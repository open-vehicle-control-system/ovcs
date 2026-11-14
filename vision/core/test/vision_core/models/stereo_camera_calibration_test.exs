defmodule VisionCore.Models.StereoCameraCalibrationTest do
  use ExUnit.Case, async: true

  alias VisionCore.Models.{Lens, StereoCameraCalibration}
  alias VisionCore.Ros2.CameraCalibration

  @name_rule "a name has 1 to 80 characters"

  defp lens(fx) do
    {:ok, attributes} =
      Lens.attributes(%CameraCalibration{
        width: 728,
        height: 544,
        distortion_model: "plumb_bob",
        distortion_coefficients: [-0.478, 0.212, -0.0003, 0.0013, 0.0],
        camera_matrix: [fx, 0.0, 364.6, 0.0, fx + 1, 298.6, 0.0, 0.0, 1.0],
        rectification_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
        projection_matrix: [864.8, 0.0, 396.4, 0.0, 0.0, 864.8, 292.7, 0.0, 0.0, 0.0, 1.0, 0.0]
      })

    attributes
  end

  defp attributes(overrides) do
    Map.merge(
      %{
        target: "stereo",
        name: "Bench",
        origin: "dashboard",
        samples: 62,
        stereo_rms_px: 0.34,
        baseline_m: 0.198,
        inserted_at: ~U[2026-11-14 10:00:00Z],
        left: lens(886.3),
        right: lens(894.3)
      },
      overrides
    )
  end

  test "takes a pair's calibration with its lenses and the session's figures" do
    changeset = StereoCameraCalibration.changeset(%StereoCameraCalibration{}, attributes(%{}))

    assert changeset.valid?
    pair = Ecto.Changeset.apply_changes(changeset)
    assert {pair.samples, pair.stereo_rms_px, pair.baseline_m} == {62, 0.34, 0.198}
    assert pair.inserted_at == ~U[2026-11-14 10:00:00Z]
    assert {pair.left.fx, pair.right.fx, pair.in_force} == {886.3, 894.3, false}
  end

  test "refuses a calibration without a target, an origin or both lenses" do
    changeset =
      StereoCameraCalibration.changeset(
        %StereoCameraCalibration{},
        attributes(%{target: nil, origin: nil, right: nil})
      )

    refute changeset.valid?
    assert {_message, [validation: :required]} = changeset.errors[:target]
    assert {_message, [validation: :required]} = changeset.errors[:origin]
    assert {_message, [validation: :required]} = changeset.errors[:right]
  end

  test "refuses a lens missing an element" do
    changeset =
      StereoCameraCalibration.changeset(
        %StereoCameraCalibration{},
        attributes(%{left: %{lens(886.3) | fx: nil}})
      )

    refute changeset.valid?
    assert {_message, [validation: :required]} = changeset.changes.left.errors[:fx]
  end

  describe "the name" do
    test "is trimmed" do
      changeset =
        StereoCameraCalibration.changeset(
          %StereoCameraCalibration{},
          attributes(%{name: "  Workshop, 30 mm board "})
        )

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :name) == "Workshop, 30 mm board"
    end

    test "has 1 to 80 characters once trimmed" do
      for name <- ["", "   ", nil, String.duplicate("a", 81)] do
        changeset =
          StereoCameraCalibration.changeset(%StereoCameraCalibration{}, attributes(%{name: name}))

        assert {@name_rule, _validation} = changeset.errors[:name]
      end

      assert StereoCameraCalibration.changeset(
               %StereoCameraCalibration{},
               attributes(%{name: String.duplicate("é", 80)})
             ).valid?
    end

    test "is refused on a kept calibration as on a new one" do
      kept = %StereoCameraCalibration{target: "stereo", name: "Bench", origin: "dashboard"}

      assert {@name_rule, _validation} =
               StereoCameraCalibration.changeset(kept, %{name: "   "}).errors[:name]

      assert StereoCameraCalibration.changeset(kept, %{name: " Workshop "}).changes == %{
               name: "Workshop"
             }
    end
  end
end

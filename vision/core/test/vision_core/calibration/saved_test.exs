defmodule VisionCore.Calibration.SavedTest do
  use ExUnit.Case, async: true

  alias VisionCore.Calibration.{Saved, SavedCamera}
  alias VisionCore.Ros2.CameraCalibration

  @name_rule "a name has 1 to 80 characters"

  defp camera(name) do
    {:ok, attributes} =
      SavedCamera.attributes(name, %CameraCalibration{
        width: 728,
        height: 544,
        distortion_model: "plumb_bob",
        distortion_coefficients: [-0.478, 0.212, -0.0003, 0.0013, 0.0],
        camera_matrix: [886.3, 0.0, 364.6, 0.0, 887.3, 298.6, 0.0, 0.0, 1.0],
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
        inserted_at: ~U[2026-11-14 10:00:00Z],
        cameras: [camera("left"), camera("right")]
      },
      overrides
    )
  end

  test "takes a calibration with its cameras and the session's figures" do
    changeset = Saved.changeset(%Saved{}, attributes(%{}))

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :samples) == 62
    assert Ecto.Changeset.get_change(changeset, :inserted_at) == ~U[2026-11-14 10:00:00Z]
    assert [%{valid?: true}, %{valid?: true}] = Ecto.Changeset.get_change(changeset, :cameras)
  end

  test "refuses a calibration without a target or an origin" do
    changeset = Saved.changeset(%Saved{}, attributes(%{target: nil, origin: nil}))

    refute changeset.valid?
    assert {_message, [validation: :required]} = changeset.errors[:target]
    assert {_message, [validation: :required]} = changeset.errors[:origin]
  end

  describe "the name" do
    test "is trimmed" do
      changeset = Saved.changeset(%Saved{}, attributes(%{name: "  Workshop, 30 mm board "}))

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :name) == "Workshop, 30 mm board"
    end

    test "has 1 to 80 characters once trimmed" do
      for name <- ["", "   ", nil, String.duplicate("a", 81)] do
        changeset = Saved.changeset(%Saved{}, attributes(%{name: name}))
        assert {@name_rule, _validation} = changeset.errors[:name]
      end

      assert Saved.changeset(%Saved{}, attributes(%{name: String.duplicate("é", 80)})).valid?
    end

    test "is refused on a kept calibration as on a new one" do
      kept = %Saved{target: "stereo", name: "Bench", origin: "dashboard"}

      assert {@name_rule, _validation} = Saved.changeset(kept, %{name: "   "}).errors[:name]
      assert Saved.changeset(kept, %{name: " Workshop "}).changes == %{name: "Workshop"}
    end
  end
end

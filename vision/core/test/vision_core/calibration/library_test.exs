defmodule VisionCore.Calibration.LibraryTest do
  use ExUnit.Case, async: false

  alias VisionCore.Calibration.{Library, Saved, SavedCamera, Selection}
  alias VisionCore.Repo
  alias VisionCore.Ros2.CameraCalibration

  setup do
    Repo.delete_all(Selection)
    Repo.delete_all(Saved)
    :ok
  end

  defp calibration(fx) do
    %CameraCalibration{
      width: 728,
      height: 544,
      distortion_model: "plumb_bob",
      distortion_coefficients: [-0.478, 0.212, -0.0003, 0.0013, 0.0],
      camera_matrix: [fx, 0.0, 364.6, 0.0, fx + 1, 298.6, 0.0, 0.0, 1.0],
      rectification_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
      projection_matrix: [864.8, 0.0, 396.4, -171.2, 0.0, 864.8, 292.7, 0.0, 0.0, 0.0, 1.0, 0.0]
    }
  end

  defp pair(fx), do: [{"left", calibration(fx)}, {"right", calibration(fx + 8)}]

  describe "record/3" do
    test "keeps a calibration with its cameras, each figure in its own column, and the session's figures" do
      {:ok, saved} =
        Library.record("stereo", pair(886.3),
          origin: "dashboard",
          board: %{columns: 8, rows: 6, square_m: 0.03},
          samples: 62,
          stereo_rms_px: 0.34,
          baseline_m: 0.198,
          rms_px: %{"left" => 0.21, "right" => 0.3}
        )

      assert %Saved{target: "stereo", origin: "dashboard", samples: 62, stereo_rms_px: 0.34} =
               saved

      assert {saved.board_columns, saved.board_rows, saved.board_square_m} == {8, 6, 0.03}

      assert [%SavedCamera{name: "left", fx: 886.3, k1: -0.478, p03: -171.2, rms_px: 0.21}, right] =
               saved.cameras

      assert {right.name, right.fx, right.rms_px} == {"right", 894.3, 0.3}
      assert SavedCamera.to_calibration(hd(saved.cameras)) == calibration(886.3)
    end

    test "keeps a pose, each element in its own column, with no camera, and its error" do
      pose = %VisionCore.Camera.Pose{
        rotation: [0.999, -0.02, 0.04, 0.02, 0.9998, 0.001, -0.04, 0.0, 0.9992],
        translation: [-0.1, 0.005, 0.002]
      }

      {:ok, saved} =
        Library.record("center-pose", pose, origin: "dashboard", samples: 24, rms_px: 0.41)

      {:ok, kept} = Library.fetch(saved.id)
      assert kept.cameras == []
      assert %VisionCore.Calibration.SavedPose{r01: -0.02, tx: -0.1, rms_px: 0.41} = kept.pose
      assert VisionCore.Calibration.SavedPose.to_pose(kept.pose) == pose
      assert Library.holds?(kept, pose)
      refute Library.holds?(kept, %{pose | translation: [-0.1, 0.005, 0.003]})
      assert Library.holding("center-pose", pose).id == saved.id
    end

    test "names a calibration after the time it was kept, unless a name is given" do
      {:ok, dated} = Library.record("stereo", pair(886.3), origin: "dashboard")
      assert dated.name =~ ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/

      {:ok, named} = Library.record("stereo", pair(886.3), origin: "imported", name: "Bench")
      assert named.name == "Bench"
    end

    test "refuses a calibration with no columns to go to, and keeps nothing" do
      rational = %{calibration(886.3) | distortion_model: "rational_polynomial"}

      assert {:error, reason} = Library.record("stereo", [{"left", rational}], origin: "imported")
      assert reason =~ "plumb_bob"
      assert Library.list("stereo") == []
    end
  end

  test "lists the calibration kept last first, whatever the dates they carry" do
    {:ok, first} =
      Library.record("stereo", pair(880.0), origin: "dashboard", at: ~U[2026-11-14 10:00:00Z])

    {:ok, second} =
      Library.record("stereo", pair(890.0), origin: "imported", at: ~U[2026-11-13 09:00:00Z])

    assert Enum.map(Library.list("stereo"), & &1.id) == [second.id, first.id]
  end

  test "lists a target's calibrations, the newest first, and no other target's" do
    {:ok, first} = Library.record("stereo", pair(880.0), origin: "dashboard")
    {:ok, second} = Library.record("stereo", pair(890.0), origin: "dashboard")

    {:ok, _center} =
      Library.record("center", [{"center", calibration(580.8)}], origin: "dashboard")

    assert Enum.map(Library.list("stereo"), & &1.id) == [second.id, first.id]
    assert [%{cameras: [%{name: "left"}, %{name: "right"}]} | _] = Library.list("stereo")
    assert {:ok, %{id: id}} = Library.fetch(first.id)
    assert id == first.id
    assert Library.fetch(-1) == {:error, :not_found}
  end

  test "renames a calibration with a name of 1 to 80 characters, trimmed" do
    {:ok, saved} = Library.record("stereo", pair(886.3), origin: "dashboard")

    assert {:ok, %{name: "Workshop, 30 mm board"}} =
             Library.rename(saved.id, "  Workshop, 30 mm board ")

    assert {:error, "a name has 1 to 80 characters"} = Library.rename(saved.id, "   ")

    assert {:error, "a name has 1 to 80 characters"} =
             Library.rename(saved.id, String.duplicate("a", 81))

    assert Library.rename(-1, "x") == {:error, :not_found}
    assert {:ok, %{name: "Workshop, 30 mm board"}} = Library.fetch(saved.id)
  end

  describe "the selection" do
    test "is the calibration in force for a target, one at a time, or none" do
      {:ok, first} = Library.record("stereo", pair(880.0), origin: "dashboard")
      {:ok, second} = Library.record("stereo", pair(890.0), origin: "dashboard")
      assert Library.selected("stereo") == nil

      :ok = Library.select("stereo", first.id)
      :ok = Library.select("stereo", second.id)
      assert Library.selected("stereo").id == second.id
      assert Repo.aggregate(Selection, :count) == 1

      :ok = Library.select("stereo", nil)
      assert Library.selected("stereo") == nil
    end

    test "keeps a calibration in force from being deleted; another one goes with its cameras" do
      {:ok, kept} = Library.record("stereo", pair(880.0), origin: "dashboard")
      {:ok, other} = Library.record("stereo", pair(890.0), origin: "dashboard")
      :ok = Library.select("stereo", kept.id)

      assert Library.delete(kept.id) == {:error, :in_force}
      assert Library.delete(other.id) == :ok
      assert Library.delete(other.id) == {:error, :not_found}
      assert Enum.map(Library.list("stereo"), & &1.id) == [kept.id]
      assert Repo.aggregate(SavedCamera, :count) == 2
    end
  end

  test "finds the newest calibration of a target that holds given calibrations, element for element" do
    {:ok, _older} = Library.record("stereo", pair(886.3), origin: "imported")
    {:ok, newer} = Library.record("stereo", pair(886.3), origin: "dashboard")
    {:ok, _other} = Library.record("stereo", pair(900.0), origin: "dashboard")

    assert Library.holding("stereo", pair(886.3)).id == newer.id
    assert Library.holding("stereo", pair(886.4)) == nil
    assert Library.holding("stereo", [{"left", calibration(886.3)}]) == nil
    assert Library.holding("center", pair(886.3)) == nil
  end
end

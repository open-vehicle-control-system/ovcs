defmodule VisionCore.Calibration.LibraryTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias VisionCore.Calibration.Library
  alias VisionCore.Models
  alias VisionCore.Repo
  alias VisionCore.Ros2.CameraCalibration

  @models [Models.StereoCameraCalibration, Models.CameraCalibration, Models.CameraPose]
  @unknown "6f1c2a7e-3b4d-4e5f-8a9b-0c1d2e3f4a5b"

  setup do
    Enum.each(@models, &Repo.delete_all/1)
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

  defp in_use_count(model),
    do: Repo.aggregate(from(saved in model, where: saved.in_use), :count)

  describe "record/3" do
    test "saves a pair's calibration with its lenses and the session's figures" do
      {:ok, saved} =
        Library.record("stereo", pair(886.3),
          origin: "dashboard",
          board: %{columns: 8, rows: 6, square_m: 0.03},
          samples: 62,
          stereo_rms_px: 0.34,
          baseline_m: 0.198,
          rms_px: %{"left" => 0.21, "right" => 0.3}
        )

      assert %Models.StereoCameraCalibration{
               target: "stereo",
               origin: "dashboard",
               samples: 62,
               stereo_rms_px: 0.34,
               baseline_m: 0.198,
               in_use: false,
               left: %Models.Lens{fx: 886.3, k1: -0.478, rms_px: 0.21} = left,
               right: right
             } = saved

      assert {saved.board_columns, saved.board_rows, saved.board_square_m} == {8, 6, 0.03}
      assert {right.fx, right.rms_px} == {894.3, 0.3}
      assert Enum.at(left.projection, 3) == -171.2

      {:ok, fetched} = Library.fetch(saved.id)
      assert Models.Lens.to_calibration(fetched.left) == calibration(886.3)
      assert Models.Lens.to_calibration(fetched.right) == calibration(894.3)
    end

    test "saves a pair's cameras whatever their order" do
      {:ok, saved} = Library.record("stereo", Enum.reverse(pair(886.3)), origin: "dashboard")

      assert {saved.left.fx, saved.right.fx} == {886.3, 894.3}
      assert Library.lenses(saved) == [{"left", saved.left}, {"right", saved.right}]
    end

    test "saves one camera's calibration with its lens" do
      {:ok, saved} =
        Library.record("center", [{"center", calibration(580.8)}],
          origin: "dashboard",
          rms_px: %{"center" => 0.2}
        )

      assert %Models.CameraCalibration{
               target: "center",
               camera: "center",
               lens: %Models.Lens{fx: 580.8, rms_px: 0.2} = lens
             } = saved

      assert Library.lenses(saved) == [{"center", lens}]
      {:ok, fetched} = Library.fetch(saved.id)
      assert Models.Lens.to_calibration(fetched.lens) == calibration(580.8)
    end

    test "saves a camera's pose and its error" do
      pose = %VisionCore.Camera.Pose{
        rotation: [0.999, -0.02, 0.04, 0.02, 0.9998, 0.001, -0.04, 0.0, 0.9992],
        translation: [-0.1, 0.005, 0.002]
      }

      {:ok, saved} =
        Library.record("center-pose", pose, origin: "dashboard", samples: 24, rms_px: 0.41)

      {:ok, fetched} = Library.fetch(saved.id)

      assert %Models.CameraPose{camera: "center", samples: 24, rms_px: 0.41, in_use: false} =
               fetched

      assert Models.CameraPose.to_pose(fetched) == pose
      assert Library.lenses(fetched) == []
      assert Library.holds?(fetched, pose)
      refute Library.holds?(fetched, %{pose | translation: [-0.1, 0.005, 0.003]})
      assert Library.holding("center-pose", pose).id == saved.id
    end

    test "names a calibration after the time it was saved, unless a name is given" do
      {:ok, dated} =
        Library.record("stereo", pair(886.3), origin: "dashboard", at: ~U[2026-11-13 23:37:12Z])

      assert dated.name == "2026-11-13 23:37 UTC"

      {:ok, named} = Library.record("stereo", pair(886.3), origin: "imported", name: "Bench")
      assert named.name == "Bench"
    end

    test "saves the time a calibration was made" do
      {:ok, saved} =
        Library.record("stereo", pair(886.3), origin: "dashboard", at: ~U[2026-11-13 09:00:00Z])

      {:ok, fetched} = Library.fetch(saved.id)
      assert fetched.inserted_at == ~U[2026-11-13 09:00:00Z]
      assert fetched.name == "2026-11-13 09:00 UTC"
    end

    test "refuses a name of more than 80 characters, and saves nothing" do
      assert Library.record("stereo", pair(886.3),
               origin: "imported",
               name: String.duplicate("a", 81)
             ) ==
               {:error, "a name has 1 to 80 characters"}

      assert Library.list("stereo") == []
    end

    test "refuses a calibration with no columns to go to, and saves nothing" do
      rational = %{calibration(886.3) | distortion_model: "rational_polynomial"}

      assert {:error, reason} = Library.record("stereo", [{"left", rational}], origin: "imported")
      assert reason =~ "plumb_bob"
      assert Library.list("stereo") == []
    end
  end

  test "lists the calibration saved last first, whatever the dates they carry" do
    {:ok, first} =
      Library.record("stereo", pair(880.0), origin: "dashboard", at: ~U[2026-11-14 10:00:00Z])

    {:ok, second} =
      Library.record("stereo", pair(890.0), origin: "imported", at: ~U[2026-11-13 09:00:00Z])

    {:ok, third} =
      Library.record("stereo", pair(900.0), origin: "imported", at: ~U[2026-11-13 09:00:00Z])

    assert Enum.map(Library.list("stereo"), & &1.id) == [third.id, second.id, first.id]
  end

  test "lists a target's calibrations, the newest first, and no other target's" do
    {:ok, first} = Library.record("stereo", pair(880.0), origin: "dashboard")
    {:ok, second} = Library.record("stereo", pair(890.0), origin: "dashboard")

    {:ok, _center} =
      Library.record("center", [{"center", calibration(580.8)}], origin: "dashboard")

    assert Enum.map(Library.list("stereo"), & &1.id) == [second.id, first.id]

    assert [%Models.StereoCameraCalibration{left: %{fx: 890.0}, right: %{fx: 898.0}} | _] =
             Library.list("stereo")

    assert {:ok, %{id: id}} = Library.fetch(first.id)
    assert id == first.id
    assert Library.fetch(@unknown) == {:error, :not_found}
    assert Library.fetch("abc") == {:error, :not_found}
    assert Library.fetch(String.upcase(first.id)) == {:error, :not_found}
  end

  test "renames a calibration with a name of 1 to 80 characters, trimmed" do
    {:ok, saved} = Library.record("stereo", pair(886.3), origin: "dashboard")

    assert {:ok, %{name: "Workshop, 30 mm board"}} =
             Library.rename(saved.id, "  Workshop, 30 mm board ")

    assert {:error, "a name has 1 to 80 characters"} = Library.rename(saved.id, "   ")

    assert {:error, "a name has 1 to 80 characters"} =
             Library.rename(saved.id, String.duplicate("a", 81))

    assert Library.rename(@unknown, "x") == {:error, :not_found}
    assert {:ok, %{name: "Workshop, 30 mm board"}} = Library.fetch(saved.id)
  end

  test "refuses a name before looking for the calibration" do
    assert Library.rename("abc", "   ") == {:error, "a name has 1 to 80 characters"}
  end

  describe "the calibration in use" do
    test "is one calibration of a target at a time, or none" do
      {:ok, first} = Library.record("stereo", pair(880.0), origin: "dashboard")
      {:ok, second} = Library.record("stereo", pair(890.0), origin: "dashboard")
      assert Library.in_use("stereo") == nil

      :ok = Library.put_in_use("stereo", first.id)
      :ok = Library.put_in_use("stereo", second.id)
      assert Library.in_use("stereo").id == second.id
      assert in_use_count(Models.StereoCameraCalibration) == 1

      :ok = Library.put_in_use("stereo", nil)
      assert Library.in_use("stereo") == nil
    end

    test "keeps the calibration in use from being deleted; another one goes" do
      {:ok, used} = Library.record("stereo", pair(880.0), origin: "dashboard")
      {:ok, other} = Library.record("stereo", pair(890.0), origin: "dashboard")
      :ok = Library.put_in_use("stereo", used.id)

      assert Library.delete(used.id) == {:error, :in_use}
      assert Library.delete(other.id) == :ok
      assert Library.delete(other.id) == {:error, :not_found}
      assert Enum.map(Library.list("stereo"), & &1.id) == [used.id]
      assert Library.delete("abc") == {:error, :not_found}
      assert Library.delete(@unknown) == {:error, :not_found}
    end

    test "is one calibration of the target, whatever the kind of the others" do
      {:ok, center} =
        Library.record("center", [{"center", calibration(580.8)}], origin: "dashboard")

      {:ok, other} =
        Library.record("center", [{"center", calibration(590.0)}], origin: "dashboard")

      {:ok, pair} = Library.record("stereo", pair(880.0), origin: "dashboard")
      :ok = Library.put_in_use("stereo", pair.id)
      :ok = Library.put_in_use("center", center.id)

      assert {:error, _reason} = Library.put_in_use("center", pair.id)

      assert Library.put_in_use("center", "abc") ==
               {:error, ~s(no calibration "abc" is saved for center)}

      assert {:error, _reason} = Library.put_in_use("center", @unknown)
      assert Library.in_use("center").id == center.id
      assert Library.in_use("stereo").id == pair.id

      :ok = Library.put_in_use("center", other.id)
      assert Library.in_use("center").id == other.id
      assert in_use_count(Models.CameraCalibration) == 1

      :ok = Library.put_in_use("center", nil)
      assert Library.in_use("center") == nil
      assert Library.in_use("stereo").id == pair.id
    end

    test "is at most one calibration per target in the database" do
      {:ok, _first} = Library.record("stereo", pair(880.0), origin: "dashboard")
      {:ok, _second} = Library.record("stereo", pair(890.0), origin: "dashboard")

      assert_raise Exqlite.Error, ~r/UNIQUE constraint failed/, fn ->
        Repo.update_all(Models.StereoCameraCalibration, set: [in_use: true])
      end
    end
  end

  test "names a calibration of any kind by a UUID of its own" do
    {:ok, pair} = Library.record("stereo", pair(880.0), origin: "dashboard")
    {:ok, camera} = Library.record("center", [{"center", calibration(580.8)}], origin: "imported")

    pose = %VisionCore.Camera.Pose{
      rotation: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
      translation: [-0.1, 0.0, 0.0]
    }

    {:ok, pose} = Library.record("center-pose", pose, origin: "dashboard")

    ids = [pair.id, camera.id, pose.id]
    assert Enum.all?(ids, &(Ecto.UUID.cast(&1) == {:ok, &1}))
    assert length(Enum.uniq(ids)) == 3

    assert {:ok, %Models.StereoCameraCalibration{target: "stereo"}} = Library.fetch(pair.id)
    assert {:ok, %Models.CameraCalibration{target: "center"}} = Library.fetch(camera.id)
    assert {:ok, %Models.CameraPose{target: "center-pose"}} = Library.fetch(pose.id)

    :ok = Library.put_in_use("center-pose", pose.id)
    assert Library.in_use("center-pose").id == pose.id
    assert Library.delete(camera.id) == :ok
    assert Library.fetch(camera.id) == {:error, :not_found}
    assert {:ok, _pair} = Library.fetch(pair.id)
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

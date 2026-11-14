defmodule VisionCore.RepoMigrationsTest do
  # Each test migrates a database of its own, in the test process, through the repo's dynamic repo.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias VisionCore.Calibration.Library
  alias VisionCore.Models
  alias VisionCore.Repo

  @moduletag :tmp_dir

  @rectification for row <- 0..2, column <- 0..2, do: "r#{row}#{column}"
  @projection for row <- 0..2, column <- 0..3, do: "p#{row}#{column}"
  @rotation for row <- 0..2, column <- 0..2, do: "r#{row}#{column}"

  # Values a text conversion of 15 digits would round.
  @third 1 / 3
  @tenths 0.1 + 0.2

  setup %{tmp_dir: tmp_dir} do
    repo =
      start_supervised!(
        {Repo, name: nil, database: Path.join(tmp_dir, "vision.db"), pool_size: 1}
      )

    Repo.put_dynamic_repo(repo)
    %{repo: repo}
  end

  defp migrate(repo, opts),
    do: Ecto.Migrator.run(Repo, migrations(), :up, [dynamic_repo: repo, log: false] ++ opts)

  # The migrations test_helper.exs compiled, by version: compiling their files again redefines them.
  defp migrations do
    for path <- Path.wildcard("priv/repo/migrations/*.exs") do
      [version, name] = path |> Path.basename(".exs") |> String.split("_", parts: 2)
      {String.to_integer(version), Module.concat(Repo.Migrations, Macro.camelize(name))}
    end
  end

  defp insert(table, row) do
    columns = Map.keys(row)
    placeholders = Enum.map_join(columns, ", ", fn _column -> "?" end)

    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO #{table} (#{Enum.join(columns, ", ")}) VALUES (#{placeholders}) RETURNING id",
        Map.values(row)
      )

    id
  end

  defp calibration(target, row) do
    insert(
      "calibrations",
      Map.merge(
        %{
          "target" => target,
          "name" => "Bench",
          "origin" => "dashboard",
          "inserted_at" => "2026-11-13T09:00:00Z"
        },
        row
      )
    )
  end

  defp camera(calibration_id, name, fx) do
    elements = Map.new(@rectification ++ @projection, &{&1, 0.0})

    insert(
      "calibration_cameras",
      Map.merge(elements, %{
        "calibration_id" => calibration_id,
        "name" => name,
        "image_width" => 728,
        "image_height" => 544,
        "fx" => fx,
        "fy" => fx + 1,
        "cx" => 364.6,
        "cy" => 298.6,
        "k1" => -0.478,
        "k2" => @tenths,
        "p1" => -0.0003,
        "p2" => 0.0013,
        "k3" => 0.0,
        "r00" => @third,
        "p23" => -171.2,
        "rms_px" => 0.21
      })
    )
  end

  defp table_names do
    %{rows: rows} = Repo.query!("SELECT name FROM sqlite_master WHERE type = 'table'")
    List.flatten(rows)
  end

  test "marks UTC on the names kept before they said it, and only on those", %{repo: repo} do
    migrate(repo, to: 20_261_114_120_000)

    dated =
      calibration("stereo", %{
        "name" => "2026-11-13 23:37",
        "inserted_at" => "2026-11-13T23:37:12Z"
      })

    named = calibration("stereo", %{"name" => "Bench", "inserted_at" => "2026-11-13T23:38:00Z"})

    chosen =
      calibration("stereo", %{
        "name" => "2026-11-12 10:00",
        "inserted_at" => "2026-11-13T23:39:00Z"
      })

    migrate(repo, to: 20_261_114_180_000)

    names = fn id -> Repo.query!("SELECT name FROM calibrations WHERE id = ?", [id]).rows end
    assert names.(dated) == [["2026-11-13 23:37 UTC"]]
    assert names.(named) == [["Bench"]]
    assert names.(chosen) == [["2026-11-12 10:00"]]
  end

  test "moves each calibration kept to its kind's table, its cameras into lenses and its selection into in_force",
       %{repo: repo} do
    migrate(repo, to: 20_261_114_180_000)

    pair =
      calibration("hq", %{
        "name" => "Workshop",
        "board_columns" => 8,
        "board_rows" => 6,
        "board_square_m" => 0.03,
        "samples" => 62,
        "stereo_rms_px" => 0.34,
        "baseline_m" => 0.198
      })

    camera(pair, "right", 894.3)
    camera(pair, "left", 886.3)
    older = calibration("center", %{"origin" => "imported"})
    camera(older, "center", 580.8)
    newer = calibration("center", %{"inserted_at" => "2026-11-13T10:00:00Z"})
    camera(newer, "center", 590.0)
    pose = calibration("center-pose", %{"samples" => 24})

    rotation =
      Map.new(Enum.with_index(@rotation), fn {element, index} -> {element, index / 9} end)

    insert(
      "calibration_poses",
      Map.merge(rotation, %{
        "calibration_id" => pose,
        "tx" => -0.1,
        "ty" => @tenths,
        "tz" => @third,
        "rms_px" => 0.41
      })
    )

    for {target, id} <- [{"hq", pair}, {"center", newer}, {"center-pose", pose}],
        do: insert("calibration_selections", %{"target" => target, "calibration_id" => id})

    migrate(repo, all: true)

    assert {:ok, %Models.StereoCameraCalibration{} = kept_pair} = Library.fetch("stereo-#{pair}")

    assert %{
             target: "hq",
             name: "Workshop",
             origin: "dashboard",
             in_force: true,
             board_columns: 8,
             board_rows: 6,
             board_square_m: 0.03,
             samples: 62,
             stereo_rms_px: 0.34,
             baseline_m: 0.198,
             inserted_at: ~U[2026-11-13 09:00:00Z]
           } = kept_pair

    assert %Models.Lens{
             image_width: 728,
             image_height: 544,
             fx: 886.3,
             fy: 887.3,
             cx: 364.6,
             cy: 298.6,
             k1: -0.478,
             k2: @tenths,
             p1: -0.0003,
             p2: 0.0013,
             k3: +0.0,
             rms_px: 0.21
           } = kept_pair.left

    assert kept_pair.left.rectification == [@third | List.duplicate(0.0, 8)]
    assert kept_pair.left.projection == List.duplicate(0.0, 11) ++ [-171.2]
    assert kept_pair.right.fx == 894.3

    assert [%{id: newer_id, in_force: true}, %{id: older_id, in_force: false, origin: "imported"}] =
             Library.list("center")

    assert {newer_id, older_id} == {"camera-#{newer}", "camera-#{older}"}

    assert {:ok, %Models.CameraCalibration{camera: "center", lens: %{fx: 580.8}}} =
             Library.fetch(older_id)

    assert {:ok, %Models.CameraPose{} = kept_pose} = Library.fetch("pose-#{pose}")

    assert %{target: "center-pose", camera: "center", in_force: true, samples: 24, rms_px: 0.41} =
             kept_pose

    assert kept_pose.rotation == Enum.map(0..8, &(&1 / 9))
    assert kept_pose.translation_m == [-0.1, @tenths, @third]

    for old <- [
          "calibrations",
          "calibration_cameras",
          "calibration_poses",
          "calibration_selections"
        ],
        do: refute(old in table_names())

    assert {:ok, %{id: next}} =
             Library.record("center", [{"center", Models.Lens.to_calibration(kept_pair.left)}],
               origin: "dashboard"
             )

    refute next in [newer_id, older_id]
  end

  test "drops a calibration of no kind kept, saying which", %{repo: repo} do
    migrate(repo, to: 20_261_114_180_000)
    without_camera = calibration("center", %{})
    unknown_pair = calibration("hq", %{})
    camera(unknown_pair, "front", 580.8)
    camera(unknown_pair, "back", 590.0)

    log = capture_log(fn -> migrate(repo, all: true) end)

    assert log =~ "calibration #{without_camera} of center is no kind kept: dropped"
    assert log =~ "calibration #{unknown_pair} of hq is no kind kept: dropped"
    assert Library.list("center") == []
    assert Library.list("hq") == []
  end
end

defmodule VisionCore.Repo.Migrations.SplitSavedCalibrationsByKind do
  use Ecto.Migration

  require Logger

  @distortion ["k1", "k2", "p1", "p2", "k3"]
  @rectification for row <- 0..2, column <- 0..2, do: "r#{row}#{column}"
  @projection for row <- 0..2, column <- 0..3, do: "p#{row}#{column}"
  @rotation for row <- 0..2, column <- 0..2, do: "r#{row}#{column}"
  @shared [
    "target",
    "name",
    "origin",
    "board_columns",
    "board_rows",
    "board_square_m",
    "samples",
    "inserted_at"
  ]

  # No down: the lenses' JSON would have to go back into the columns of calibration_cameras.
  def up do
    create_table(:stereo_camera_calibrations, fn ->
      add(:stereo_rms_px, :float)
      add(:baseline_m, :float)
      add(:left, :map, null: false)
      add(:right, :map, null: false)
    end)

    create_table(:camera_calibrations, fn ->
      add(:camera, :string, null: false)
      add(:lens, :map, null: false)
    end)

    create_table(:camera_poses, fn ->
      add(:camera, :string, null: false)
      add(:rotation, {:array, :float}, null: false)
      add(:translation_m, {:array, :float}, null: false)
      add(:rms_px, :float)
    end)

    flush()
    Enum.each(saved(), &copy/1)

    drop(table(:calibration_selections))
    drop(table(:calibration_poses))
    drop(table(:calibration_cameras))
    drop(table(:calibrations))
  end

  defp create_table(name, own_columns) do
    create table(name, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:target, :string, null: false)
      add(:name, :string, null: false)
      add(:origin, :string, null: false)
      add(:in_use, :boolean, null: false, default: false)
      add(:board_columns, :integer)
      add(:board_rows, :integer)
      add(:board_square_m, :float)
      add(:samples, :integer)
      own_columns.()
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create(index(name, [:target]))
    create(unique_index(name, [:target], where: "in_use", name: :"#{name}_in_use_index"))
  end

  # Each saved calibration with its cameras, its pose, and whether its target uses it.
  defp saved do
    calibrations =
      rows("""
      SELECT c.*, s.id IS NOT NULL AS in_use FROM calibrations c
      LEFT JOIN calibration_selections s ON s.calibration_id = c.id AND s.target = c.target
      ORDER BY c.id
      """)

    cameras = Enum.group_by(rows("SELECT * FROM calibration_cameras"), & &1["calibration_id"])
    poses = Map.new(rows("SELECT * FROM calibration_poses"), &{&1["calibration_id"], &1})

    for calibration <- calibrations do
      Map.merge(calibration, %{
        "cameras" => Map.get(cameras, calibration["id"], []),
        "pose" => poses[calibration["id"]]
      })
    end
  end

  defp rows(sql) do
    %{columns: columns, rows: rows} = repo().query!(sql)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  defp copy(%{"pose" => %{} = pose} = saved) do
    insert("camera_poses", saved, %{
      "camera" => String.replace_suffix(saved["target"], "-pose", ""),
      "rotation" => Jason.encode!(Enum.map(@rotation, &pose[&1])),
      "translation_m" => Jason.encode!([pose["tx"], pose["ty"], pose["tz"]]),
      "rms_px" => pose["rms_px"]
    })
  end

  defp copy(%{"cameras" => [camera]} = saved),
    do: insert("camera_calibrations", saved, %{"camera" => camera["name"], "lens" => lens(camera)})

  defp copy(%{"cameras" => [_, _] = cameras} = saved) do
    case Enum.sort_by(cameras, & &1["name"]) do
      [%{"name" => "left"} = left, %{"name" => "right"} = right] ->
        insert("stereo_camera_calibrations", saved, %{
          "stereo_rms_px" => saved["stereo_rms_px"],
          "baseline_m" => saved["baseline_m"],
          "left" => lens(left),
          "right" => lens(right)
        })

      _other ->
        drop_unknown(saved)
    end
  end

  defp copy(saved), do: drop_unknown(saved)

  # The library never saved such a calibration: no table takes it.
  defp drop_unknown(saved),
    do: Logger.warning("calibration #{saved["id"]} of #{saved["target"]} is no kind saved: dropped")

  # The JSON Ecto stores a VisionCore.Models.Lens as.
  defp lens(camera) do
    fields =
      ["image_width", "image_height", "fx", "fy", "cx", "cy", "rms_px" | @distortion]
      |> Map.new(&{&1, camera[&1]})
      |> Map.merge(%{
        "rectification" => Enum.map(@rectification, &camera[&1]),
        "projection" => Enum.map(@projection, &camera[&1])
      })

    Jason.encode!(fields)
  end

  defp insert(table, saved, own) do
    row =
      saved
      |> Map.take(@shared)
      |> Map.merge(%{"id" => Ecto.UUID.generate(), "in_use" => saved["in_use"]})
      |> Map.merge(own)

    columns = Map.keys(row)
    placeholders = Enum.map_join(columns, ", ", fn _column -> "?" end)

    repo().query!(
      "INSERT INTO #{table} (#{Enum.join(columns, ", ")}) VALUES (#{placeholders})",
      Map.values(row)
    )
  end
end

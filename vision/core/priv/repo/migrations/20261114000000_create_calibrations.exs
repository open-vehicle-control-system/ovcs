defmodule VisionCore.Repo.Migrations.CreateCalibrations do
  use Ecto.Migration

  @rectification for row <- 0..2, column <- 0..2, do: :"r#{row}#{column}"
  @projection for row <- 0..2, column <- 0..3, do: :"p#{row}#{column}"

  def change do
    create table(:calibrations) do
      add(:target, :string, null: false)
      add(:name, :string, null: false)
      add(:origin, :string, null: false)
      add(:board_columns, :integer)
      add(:board_rows, :integer)
      add(:board_square_m, :float)
      add(:samples, :integer)
      add(:stereo_rms_px, :float)
      add(:baseline_m, :float)
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create(index(:calibrations, [:target]))

    create table(:calibration_cameras) do
      add(:calibration_id, references(:calibrations, on_delete: :delete_all), null: false)
      add(:name, :string, null: false)
      add(:image_width, :integer, null: false)
      add(:image_height, :integer, null: false)
      add(:fx, :float, null: false)
      add(:fy, :float, null: false)
      add(:cx, :float, null: false)
      add(:cy, :float, null: false)
      add(:k1, :float, null: false)
      add(:k2, :float, null: false)
      add(:p1, :float, null: false)
      add(:p2, :float, null: false)
      add(:k3, :float, null: false)
      add(:rms_px, :float)

      for element <- @rectification ++ @projection do
        add(element, :float, null: false)
      end
    end

    create(unique_index(:calibration_cameras, [:calibration_id, :name]))

    create table(:calibration_selections) do
      add(:target, :string, null: false)
      add(:calibration_id, references(:calibrations, on_delete: :delete_all), null: false)
    end

    create(unique_index(:calibration_selections, [:target]))
  end
end

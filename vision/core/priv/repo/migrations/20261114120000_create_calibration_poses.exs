defmodule VisionCore.Repo.Migrations.CreateCalibrationPoses do
  use Ecto.Migration

  @rotation for row <- 0..2, column <- 0..2, do: :"r#{row}#{column}"

  def change do
    create table(:calibration_poses) do
      add(:calibration_id, references(:calibrations, on_delete: :delete_all), null: false)

      for element <- @rotation ++ [:tx, :ty, :tz] do
        add(element, :float, null: false)
      end

      add(:rms_px, :float)
    end

    create(unique_index(:calibration_poses, [:calibration_id]))
  end
end

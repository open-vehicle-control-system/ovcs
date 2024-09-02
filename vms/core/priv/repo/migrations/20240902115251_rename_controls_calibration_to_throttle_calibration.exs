defmodule VmsCore.Repo.Migrations.RenameControlsCalibrationToThrottleCalibration do
  use Ecto.Migration

  def change do
    rename table(:ControlsCalibration),  to: table(:throttle_calibrations)
  end
end

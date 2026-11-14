defmodule VisionCore.Repo.Migrations.MarkUtcInCalibrationNames do
  use Ecto.Migration

  # A name equal to the minute it was kept is the default name, which is in UTC.
  @default "strftime('%Y-%m-%d %H:%M', inserted_at)"

  def change do
    execute(
      "UPDATE calibrations SET name = name || ' UTC' WHERE name = #{@default}",
      "UPDATE calibrations SET name = #{@default} WHERE name = #{@default} || ' UTC'"
    )
  end
end

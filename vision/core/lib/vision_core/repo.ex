defmodule VisionCore.Repo do
  @moduledoc """
  The vision unit's SQLite repository, holding the saved parameter values
  (`VisionCore.Models.ParameterValue`), the saved calibrations
  (`VisionCore.Calibration.Library`) and the disks recordings go on
  (`VisionCore.Disks`).
  """
  use Ecto.Repo,
    otp_app: :vision_core,
    adapter: Ecto.Adapters.SQLite3
end

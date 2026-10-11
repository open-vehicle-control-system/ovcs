defmodule VmsCore.Repo do
  @moduledoc """
  The VMS's SQLite repository, holding persisted calibrations such as
  `VmsCore.Models.ThrottleCalibration`.
  """
  use Ecto.Repo,
    otp_app: :vms_core,
    adapter: Ecto.Adapters.SQLite3
end

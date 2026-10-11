defmodule VmsCore.Models.ThrottleCalibration do
  @moduledoc """
  A throttle pedal calibration value, stored by key in `VmsCore.Repo`
  and read back by `VmsCore.Components.OVCS.ThrottlePedal`.
  """
  use Ecto.Schema

  schema "throttle_calibrations" do
    field(:key, :string)
    field(:value, :integer)
    timestamps()
  end
end

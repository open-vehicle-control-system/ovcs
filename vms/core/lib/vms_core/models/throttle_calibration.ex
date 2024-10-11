defmodule VmsCore.Models.ThrottleCalibration do
  @moduledoc """
    Store the calibration values from the throttle pedal
  """
  use Ecto.Schema

  schema "throttle_calibrations" do
    field :key, :string
    field :value, :integer
    timestamps()
  end
end

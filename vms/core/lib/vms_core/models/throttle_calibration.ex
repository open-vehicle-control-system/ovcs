defmodule VmsCore.Models.ThrottleCalibration do
  use Ecto.Schema

  schema "throttle_calibrations" do
    field :key, :string
    field :value, :integer
    timestamps()
  end
end

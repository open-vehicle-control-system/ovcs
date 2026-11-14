defmodule VmsCore.Models.ThrottleCalibration do
  @moduledoc """
  A throttle pedal calibration value, stored by key in `VmsCore.Repo`
  and read back by `VmsCore.Components.OVCS.ThrottlePedal`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "throttle_calibrations" do
    field(:key, :string)
    field(:value, :integer)
    timestamps()
  end

  @doc "The changeset of `calibration` with `attributes`, its `key` and `value`."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = calibration, attributes),
    do: cast(calibration, attributes, [:key, :value])
end

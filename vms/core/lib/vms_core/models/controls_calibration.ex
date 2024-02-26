defmodule VmsCore.ControlsCalibration do
  use Ecto.Schema

  schema "ControlsCalibration" do
    field :key, :string
    field :value, :integer
    timestamps()
  end
end

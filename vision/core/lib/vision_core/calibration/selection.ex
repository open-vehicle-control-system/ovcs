defmodule VisionCore.Calibration.Selection do
  @moduledoc """
  Which `VisionCore.Calibration.Saved` is in force for a `target`. A
  target without a selection runs on the firmware's calibration, or on
  none.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias VisionCore.Calibration.Saved

  @type t :: %__MODULE__{}

  schema "calibration_selections" do
    field(:target, :string)
    belongs_to(:calibration, Saved)
  end

  @doc "The changeset of `selection` with `attributes`, its `target` and `calibration_id`."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = selection, attributes) do
    selection
    |> cast(attributes, [:target, :calibration_id])
    |> validate_required([:target, :calibration_id])
  end
end

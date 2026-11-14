defmodule VisionCore.Parameters.SavedValue do
  @moduledoc """
  A saved parameter value: the parameter's id and its value encoded as JSON.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "saved_parameter_values" do
    field(:parameter_id, :string)
    field(:value, :string)
    timestamps()
  end

  @doc "The changeset of `saved_value` with `attributes`, its `parameter_id` and `value`."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = saved_value, attributes) do
    saved_value
    |> cast(attributes, [:parameter_id, :value])
    |> validate_required([:parameter_id, :value])
  end
end

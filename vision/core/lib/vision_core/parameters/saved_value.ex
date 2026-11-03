defmodule VisionCore.Parameters.SavedValue do
  @moduledoc """
  A saved parameter value: the parameter's id and its value encoded as JSON.
  """
  use Ecto.Schema

  schema "saved_parameter_values" do
    field(:parameter_id, :string)
    field(:value, :string)
    timestamps()
  end
end

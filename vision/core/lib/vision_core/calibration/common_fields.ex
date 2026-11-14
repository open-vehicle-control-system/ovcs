defmodule VisionCore.Calibration.CommonFields do
  @moduledoc "The fields every calibration model shares, cast by `changeset/3`."
  import Ecto.Changeset

  @fields [
    :target,
    :name,
    :origin,
    :in_use,
    :board_columns,
    :board_rows,
    :board_square_m,
    :samples,
    :inserted_at
  ]
  @max_name 80
  @name_rule "a name has 1 to #{@max_name} characters"

  @doc """
  The changeset of `saved` with `attributes`, the fields every
  calibration model shares and its own `fields`. A name is trimmed and has 1 to
  #{@max_name} characters.
  """
  @spec changeset(Ecto.Schema.t(), map(), [atom()]) :: Ecto.Changeset.t()
  def changeset(saved, attributes, fields) do
    saved
    |> cast(attributes, @fields ++ fields)
    |> validate_required([:target, :origin])
    |> validate_name()
  end

  @doc "`:ok` for a name a saved calibration can take, or the rule it breaks."
  @spec check_name(String.t()) :: :ok | {:error, String.t()}
  def check_name(name) do
    changeset = {%{}, %{name: :string}} |> cast(%{name: name}, [:name]) |> validate_name()

    case changeset.errors[:name] do
      nil -> :ok
      {rule, _validation} -> {:error, rule}
    end
  end

  defp validate_name(changeset) do
    changeset
    |> update_change(:name, &trim/1)
    |> validate_required(:name, message: @name_rule)
    |> validate_length(:name, min: 1, max: @max_name, message: @name_rule)
  end

  defp trim(nil), do: nil
  defp trim(name), do: String.trim(name)
end

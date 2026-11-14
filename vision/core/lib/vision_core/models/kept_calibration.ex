defmodule VisionCore.Models.KeptCalibration do
  @moduledoc """
  What every calibration the unit keeps has, whatever its kind
  (`VisionCore.Models.StereoCameraCalibration`,
  `VisionCore.Models.CameraCalibration`, `VisionCore.Models.CameraPose`):
  the `target` it calibrates (`VisionCore.Calibration.target/0`'s `id`),
  its `name`, its `origin` (`dashboard` for one applied from a session,
  `imported` for one found in the store), whether it is `in_force` for its
  target, the board and the count of views of the session that solved it,
  `nil` for one the unit did not solve, and when it was kept. A target
  with none in force runs on the firmware's calibration, or on none.
  """
  import Ecto.Changeset

  @fields [
    :target,
    :name,
    :origin,
    :in_force,
    :board_columns,
    :board_rows,
    :board_square_m,
    :samples,
    :inserted_at
  ]
  @max_name 80
  @name_rule "a name has 1 to #{@max_name} characters"

  @doc """
  The changeset of `kept` with `attributes`, the fields every calibration
  kept has and its own `fields`. A name is trimmed and has 1 to
  #{@max_name} characters.
  """
  @spec changeset(Ecto.Schema.t(), map(), [atom()]) :: Ecto.Changeset.t()
  def changeset(kept, attributes, fields) do
    kept
    |> cast(attributes, @fields ++ fields)
    |> validate_required([:target, :origin])
    |> validate_name()
  end

  @doc "`:ok` for a name a calibration kept can take, or the rule it breaks."
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

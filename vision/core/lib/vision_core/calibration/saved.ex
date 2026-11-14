defmodule VisionCore.Calibration.Saved do
  @moduledoc """
  A calibration the unit keeps: the `target` it calibrates
  (`VisionCore.Calibration.target/0`'s `id`), its `name`, its `origin`
  (`dashboard` for one applied from a session, `imported` for one found
  in the store), the board and the count of views of the session that
  solved it, a pair's reprojection error and baseline, and its
  `VisionCore.Calibration.SavedCamera`s, or, kept for a camera's pose, its
  `VisionCore.Calibration.SavedPose` and no camera. The session's figures
  are `nil` for a calibration the unit did not solve.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias VisionCore.Calibration.{SavedCamera, SavedPose}

  @type t :: %__MODULE__{}

  @fields [
    :target,
    :name,
    :origin,
    :board_columns,
    :board_rows,
    :board_square_m,
    :samples,
    :stereo_rms_px,
    :baseline_m,
    :inserted_at
  ]
  @max_name 80
  @name_rule "a name has 1 to #{@max_name} characters"

  schema "calibrations" do
    field(:target, :string)
    field(:name, :string)
    field(:origin, :string)
    field(:board_columns, :integer)
    field(:board_rows, :integer)
    field(:board_square_m, :float)
    field(:samples, :integer)
    field(:stereo_rms_px, :float)
    field(:baseline_m, :float)
    has_many(:cameras, SavedCamera, foreign_key: :calibration_id, preload_order: [asc: :id])
    has_one(:pose, SavedPose, foreign_key: :calibration_id)
    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  The changeset of `saved` with `attributes`, its `cameras` or its `pose`
  among them. A name is trimmed and has 1 to #{@max_name} characters.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = saved, attributes) do
    saved
    |> cast(attributes, @fields)
    |> update_change(:name, &trim/1)
    |> validate_required([:target, :origin])
    |> validate_required(:name, message: @name_rule)
    |> validate_length(:name, min: 1, max: @max_name, message: @name_rule)
    |> cast_assoc(:cameras)
    |> cast_assoc(:pose)
  end

  defp trim(nil), do: nil
  defp trim(name), do: String.trim(name)
end

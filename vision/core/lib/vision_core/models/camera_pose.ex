defmodule VisionCore.Models.CameraPose do
  @moduledoc """
  A saved position of a camera relative to the stereo pair, for the
  target `<camera>-pose`: the fields every calibration model shares
  (`VisionCore.Calibration.CommonFields`), the `camera`'s name, the
  `rotation` (3×3, row by row) and the `translation_m` of a
  `VisionCore.Camera.Pose`, and the reprojection error of the solve that
  made it, when known.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias VisionCore.Camera.Pose
  alias VisionCore.Calibration.CommonFields

  @rotation_size 9
  @translation_size 3
  @required [:camera, :rotation, :translation_m]

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "camera_poses" do
    field(:target, :string)
    field(:name, :string)
    field(:origin, :string)
    field(:in_use, :boolean, default: false)
    field(:board_columns, :integer)
    field(:board_rows, :integer)
    field(:board_square_m, :float)
    field(:samples, :integer)
    field(:camera, :string)
    field(:rotation, {:array, :float})
    field(:translation_m, {:array, :float})
    field(:rms_px, :float)
    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "The changeset of `saved` with `attributes`; `rms_px` is not required."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = saved, attributes) do
    saved
    |> CommonFields.changeset(attributes, [:rms_px | @required])
    |> validate_required(@required)
    |> validate_length(:rotation, is: @rotation_size)
    |> validate_length(:translation_m, is: @translation_size)
  end

  @doc "The attributes of the row holding `pose`."
  @spec attributes(Pose.t()) :: map()
  def attributes(%Pose{rotation: rotation, translation: translation}),
    do: %{rotation: rotation, translation_m: translation}

  @doc "The pose `saved` holds."
  @spec to_pose(t()) :: Pose.t()
  def to_pose(%__MODULE__{} = saved),
    do: %Pose{rotation: saved.rotation, translation: saved.translation_m}

  @doc "Whether `saved` holds `pose`, element for element."
  @spec holds?(t(), Pose.t()) :: boolean()
  def holds?(%__MODULE__{} = saved, %Pose{} = pose) do
    Enum.all?(
      Enum.zip(saved.rotation ++ saved.translation_m, pose.rotation ++ pose.translation),
      fn {held, given} -> same?(held, given) end
    )
  end

  # A value read back from its file differs from the one saved by the text's rounding at most.
  defp same?(left, right), do: abs(left - right) <= 1.0e-9 * max(1.0, abs(left))
end

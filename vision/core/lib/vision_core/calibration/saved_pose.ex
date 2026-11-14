defmodule VisionCore.Calibration.SavedPose do
  @moduledoc """
  The pose of a `VisionCore.Calibration.Saved` kept for a camera's pose
  target: the rotation `r00` to `r22` and the translation `tx`, `ty`, `tz`
  in metres of a `VisionCore.Camera.Pose`, each element a column, and
  the reprojection error of the solve that made it, when known.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias VisionCore.Calibration.Saved
  alias VisionCore.Camera.Pose

  @rotation for row <- 0..2, column <- 0..2, do: :"r#{row}#{column}"
  @translation [:tx, :ty, :tz]

  @type t :: %__MODULE__{}

  schema "calibration_poses" do
    belongs_to(:calibration, Saved)
    field(:rms_px, :float)

    for element <- @rotation ++ @translation do
      field(element, :float)
    end
  end

  @doc "The changeset of `saved` with `attributes`; every element is required, `rms_px` is not."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = saved, attributes) do
    saved
    |> cast(attributes, [:rms_px | @rotation ++ @translation])
    |> validate_required(@rotation ++ @translation)
  end

  @doc "The attributes of the row holding `pose`."
  @spec attributes(Pose.t()) :: map()
  def attributes(%Pose{rotation: rotation, translation: translation}),
    do: Map.new(Enum.zip(@rotation ++ @translation, rotation ++ translation))

  @doc "The pose `saved` holds."
  @spec to_pose(t()) :: Pose.t()
  def to_pose(%__MODULE__{} = saved),
    do: %Pose{
      rotation: Enum.map(@rotation, &Map.fetch!(saved, &1)),
      translation: Enum.map(@translation, &Map.fetch!(saved, &1))
    }

  @doc "Whether `saved` holds `pose`, element for element."
  @spec holds?(t(), Pose.t()) :: boolean()
  def holds?(%__MODULE__{} = saved, %Pose{} = pose) do
    held = to_pose(saved)

    Enum.all?(
      Enum.zip(held.rotation ++ held.translation, pose.rotation ++ pose.translation),
      fn {column, value} -> same?(column, value) end
    )
  end

  # A value read back from its file differs from the column by the text's rounding at most.
  defp same?(left, right), do: abs(left - right) <= 1.0e-9 * max(1.0, abs(left))
end

defmodule VisionCore.Models.CameraCalibration do
  @moduledoc """
  A calibration of one camera's lens the unit keeps, for the target the
  camera's name: what every calibration kept has
  (`VisionCore.Models.KeptCalibration`), the `camera`'s name and its
  `lens` (`VisionCore.Models.Lens`).
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias VisionCore.Models.{KeptCalibration, KeptCalibrationId, Lens}

  @type t :: %__MODULE__{}

  @primary_key {:id, KeptCalibrationId, kind: "camera", autogenerate: true}
  schema "camera_calibrations" do
    field(:target, :string)
    field(:name, :string)
    field(:origin, :string)
    field(:in_force, :boolean, default: false)
    field(:board_columns, :integer)
    field(:board_rows, :integer)
    field(:board_square_m, :float)
    field(:samples, :integer)
    field(:camera, :string)
    embeds_one(:lens, Lens, on_replace: :update)
    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "The changeset of `kept` with `attributes`, its `lens` among them."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = kept, attributes) do
    kept
    |> KeptCalibration.changeset(attributes, [:camera])
    |> validate_required([:camera])
    |> cast_embed(:lens, required: true)
  end
end

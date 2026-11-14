defmodule VisionCore.Models.StereoCameraCalibration do
  @moduledoc """
  A calibration of the stereo pair the unit keeps, for the target the
  stereo unit's prefix: what every calibration kept has
  (`VisionCore.Models.KeptCalibration`), the `left` and `right` lenses
  (`VisionCore.Models.Lens`), and the pair's reprojection error and
  rectified baseline, when known.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias VisionCore.Models.{KeptCalibration, KeptCalibrationId, Lens}

  @type t :: %__MODULE__{}

  @primary_key {:id, KeptCalibrationId, kind: "stereo", autogenerate: true}
  schema "stereo_camera_calibrations" do
    field(:target, :string)
    field(:name, :string)
    field(:origin, :string)
    field(:in_force, :boolean, default: false)
    field(:board_columns, :integer)
    field(:board_rows, :integer)
    field(:board_square_m, :float)
    field(:samples, :integer)
    field(:stereo_rms_px, :float)
    field(:baseline_m, :float)
    embeds_one(:left, Lens, on_replace: :update)
    embeds_one(:right, Lens, on_replace: :update)
    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "The changeset of `kept` with `attributes`, its `left` and `right` lenses among them."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = kept, attributes) do
    kept
    |> KeptCalibration.changeset(attributes, [:stereo_rms_px, :baseline_m])
    |> cast_embed(:left, required: true)
    |> cast_embed(:right, required: true)
  end
end

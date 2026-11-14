defmodule VisionCore.Models.StereoCameraCalibration do
  @moduledoc """
  A saved calibration of the stereo pair, for the target the stereo
  unit's prefix: the fields every calibration model shares
  (`VisionCore.Calibration.CommonFields`), the `left` and `right` lenses
  (`VisionCore.Models.Lens`), and the pair's reprojection error and
  rectified baseline, when known.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias VisionCore.Calibration.CommonFields
  alias VisionCore.Models.Lens

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "stereo_camera_calibrations" do
    field(:target, :string)
    field(:name, :string)
    field(:origin, :string)
    field(:in_use, :boolean, default: false)
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

  @doc "The changeset of `saved` with `attributes`, its `left` and `right` lenses among them."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = saved, attributes) do
    saved
    |> CommonFields.changeset(attributes, [:stereo_rms_px, :baseline_m])
    |> cast_embed(:left, required: true)
    |> cast_embed(:right, required: true)
  end
end

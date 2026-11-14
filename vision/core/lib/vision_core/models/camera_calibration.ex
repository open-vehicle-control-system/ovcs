defmodule VisionCore.Models.CameraCalibration do
  @moduledoc """
  A saved calibration of one camera's lens, for the target the camera's
  name: the fields every calibration model shares
  (`VisionCore.Calibration.CommonFields`), the `camera`'s name and its
  `lens` (`VisionCore.Models.Lens`).
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias VisionCore.Calibration.CommonFields
  alias VisionCore.Models.Lens

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "camera_calibrations" do
    field(:target, :string)
    field(:name, :string)
    field(:origin, :string)
    field(:in_use, :boolean, default: false)
    field(:board_columns, :integer)
    field(:board_rows, :integer)
    field(:board_square_m, :float)
    field(:samples, :integer)
    field(:camera, :string)
    embeds_one(:lens, Lens, on_replace: :update)
    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "The changeset of `saved` with `attributes`, its `lens` among them."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = saved, attributes) do
    saved
    |> CommonFields.changeset(attributes, [:camera])
    |> validate_required([:camera])
    |> cast_embed(:lens, required: true)
  end
end

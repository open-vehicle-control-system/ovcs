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

  alias VisionCore.Calibration.{SavedCamera, SavedPose}

  @type t :: %__MODULE__{}

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
end

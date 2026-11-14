defmodule VisionCore.Calibration.Selection do
  @moduledoc """
  Which `VisionCore.Calibration.Saved` is in force for a `target`. A
  target without a selection runs on the firmware's calibration, or on
  none.
  """
  use Ecto.Schema

  alias VisionCore.Calibration.Saved

  schema "calibration_selections" do
    field(:target, :string)
    belongs_to(:calibration, Saved)
  end
end

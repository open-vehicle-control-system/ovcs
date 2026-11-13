defmodule VisionApiWeb.CalibrationUnit do
  @moduledoc """
  What the calibration routes and channel work on: the active
  `VisionCore.Config` and the targets it can calibrate
  (`VisionCore.Calibration.targets/1`).
  """

  @doc "The active configuration, an empty one while the vision core runs none."
  @spec config() :: VisionCore.Config.t()
  def config, do: VisionCore.Application.active_config() || %VisionCore.Config{}

  @doc "The targets the unit can calibrate, none while the vision core runs no configuration."
  @spec targets() :: [VisionCore.Calibration.target()]
  def targets, do: VisionCore.Calibration.targets(config())
end

defmodule VisionApiWeb.CalibrationPose do
  @moduledoc """
  A camera's pose as the `calibrations` and `saved-calibrations`
  resources and the calibration session carry it: its `rotation`,
  row-major, its `translation` in metres, the `distanceMm` between the
  two cameras, and the `file` to save its `yaml` under.
  """
  alias VisionCore.Camera.Pose

  @doc "The attributes of `pose`, saved under `file` as `yaml`."
  @spec attributes(Pose.t(), String.t(), String.t()) :: map()
  def attributes(%Pose{} = pose, file, yaml),
    do: %{
      rotation: pose.rotation,
      translation: pose.translation,
      distanceMm: Pose.distance_m(pose) * 1000,
      file: file,
      yaml: yaml
    }
end

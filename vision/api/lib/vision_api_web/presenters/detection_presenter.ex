defmodule VisionApiWeb.DetectionPresenter do
  @moduledoc """
  A `VisionCore.Detection.Live` detection as the `"detections"` event
  presents it: `label`, `score`, `distanceM` and `outline`, the closed
  list of `[x, y]` vertices as fractions of the left image's width and
  height.
  """

  @doc "One of `VisionCore.Detection.Live`'s detections, as the `\"detections\"` event lists it."
  @spec present(map()) :: map()
  def present(detection) do
    %{
      label: detection.label,
      score: detection.score,
      distanceM: detection.distance_m,
      outline: detection.outline
    }
  end
end

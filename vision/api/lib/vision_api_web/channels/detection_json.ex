defmodule VisionApiWeb.DetectionJSON do
  @moduledoc """
  `VisionCore.Detection.Live`'s detections as the `"detections"` event's
  payload, `%{detections: [detection]}`. Each detection has its `label`,
  `score`, `distanceM`, `nil` for one without a distance, and `outline`,
  the closed list of `[x, y]` vertices as fractions of the width and
  height of its pipeline's source image: the left camera's, or a camera
  of its own's.
  """

  @doc "The `\"detections\"` event's payload for `detections`."
  @spec detections([map()]) :: map()
  def detections(detections), do: %{detections: Enum.map(detections, &data/1)}

  defp data(detection) do
    %{
      label: detection.label,
      score: detection.score,
      distanceM: detection.distance_m,
      outline: detection.outline
    }
  end
end

defmodule VisionApiWeb.DetectionJSON do
  @moduledoc """
  `VisionCore.Detection.Live`'s detections as the `"detections"` event's
  payload, `%{detections: [detection]}`. Each detection has its `label`,
  `score`, `distanceM` and `outline`, the closed list of `[x, y]` vertices
  as fractions of the left image's width and height.
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

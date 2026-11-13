defmodule VisionApiWeb.DetectionJSON do
  @moduledoc """
  `VisionCore.Detection.Live`'s detections as the `"detections"` event's
  payload, `%{captureUs:, detections: [detection]}`: the capture time of
  the frame they were found on, in microseconds on the unit's monotonic
  clock, as the `"video:<camera>"` frames carry it
  (`VisionApiWeb.VideoChannel`), then the detections. Each detection has its `label`,
  `score`, `distanceM`, `nil` for one without a distance, and `outline`,
  the closed list of `[x, y]` vertices as fractions of the width and
  height of its pipeline's source image: the left camera's, or a camera
  of its own's.
  """

  @doc "The `\"detections\"` event's payload for a `VisionCore.Detection.Live` result."
  @spec detections(%{capture_ns: integer(), detections: [map()]}) :: map()
  def detections(%{capture_ns: capture_ns, detections: detections}),
    do: %{captureUs: div(capture_ns, 1_000), detections: Enum.map(detections, &data/1)}

  defp data(detection) do
    %{
      label: detection.label,
      score: detection.score,
      distanceM: detection.distance_m,
      outline: detection.outline
    }
  end
end

defmodule VisionApiWeb.DashboardSocket do
  @moduledoc "The dashboard's socket: the `status`, `preview:<stream>`, `video:<camera>`, `detections:<name>`, `segmentation:<name>`, `calibration` and `parameters` channels."
  use Phoenix.Socket

  channel "status", VisionApiWeb.StatusChannel
  channel "preview:*", VisionApiWeb.PreviewChannel
  channel "video:*", VisionApiWeb.VideoChannel
  channel "detections:*", VisionApiWeb.DetectionChannel
  channel "segmentation:*", VisionApiWeb.SegmentationChannel
  channel "calibration", VisionApiWeb.CalibrationChannel
  channel "parameters", VisionApiWeb.ParametersChannel

  @impl Phoenix.Socket
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl Phoenix.Socket
  def id(_socket), do: nil
end

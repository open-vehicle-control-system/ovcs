defmodule VisionApiWeb.DashboardSocket do
  @moduledoc "The dashboard's socket: the `status`, `preview:<stream>`, `detections:<name>` and `segmentation:<name>` channels."
  use Phoenix.Socket

  channel "status", VisionApiWeb.StatusChannel
  channel "preview:*", VisionApiWeb.PreviewChannel
  channel "detections:*", VisionApiWeb.DetectionChannel
  channel "segmentation:*", VisionApiWeb.SegmentationChannel

  @impl Phoenix.Socket
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl Phoenix.Socket
  def id(_socket), do: nil
end

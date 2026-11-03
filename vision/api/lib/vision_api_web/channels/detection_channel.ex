defmodule VisionApiWeb.DetectionChannel do
  @moduledoc """
  Pushes `VisionCore.Detection.Live`'s results on `"detections"` as
  `"detections"` events, shaped by `VisionApiWeb.DetectionJSON`. Stops
  when `VisionCore.Detection.Live` restarts, and refuses the join while it
  is not running, as on a unit without detection; see
  `VisionApiWeb.SourceMonitor`.
  """
  # On a unit without detection, the client keeps retrying the refused join.
  use VisionApiWeb, {:channel, log_join: :debug}

  alias VisionApiWeb.{DetectionJSON, SourceMonitor}

  @impl Phoenix.Channel
  def join("detections", _payload, socket),
    do:
      SourceMonitor.join(
        socket,
        VisionCore.Detection.Live,
        &VisionCore.Detection.Live.subscribe/0
      )

  @impl Phoenix.Channel
  def handle_info({:vision_detections, detections}, socket) do
    push(socket, "detections", DetectionJSON.detections(detections))
    {:noreply, socket}
  end

  def handle_info({:DOWN, monitor_reference, :process, _pid, _reason}, socket),
    do: SourceMonitor.handle_down(monitor_reference, socket)
end

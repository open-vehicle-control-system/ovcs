defmodule VisionApiWeb.DetectionChannel do
  @moduledoc """
  Pushes `VisionCore.Detection.Live`'s results on `"detections"` as
  `"detections"` events, `%{detections: [detection]}`, each presented by
  `VisionApiWeb.DetectionPresenter`. Stops when `VisionCore.Detection.Live`
  restarts, and refuses the join while it is not running, as on a unit
  without detection; see `VisionApiWeb.SourceMonitor`.
  """
  use VisionApiWeb, :channel

  alias VisionApiWeb.{DetectionPresenter, SourceMonitor}

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
    push(socket, "detections", %{detections: Enum.map(detections, &DetectionPresenter.present/1)})
    {:noreply, socket}
  end

  def handle_info({:DOWN, monitor_reference, :process, _pid, _reason}, socket),
    do: SourceMonitor.handle_down(monitor_reference, socket)
end

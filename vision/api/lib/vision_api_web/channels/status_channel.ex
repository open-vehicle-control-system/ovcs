defmodule VisionApiWeb.StatusChannel do
  @moduledoc """
  Pushes `VisionCore.Status` snapshots as `"status"`: one on join, then
  one a second. Stops when `VisionCore.Status` restarts, and refuses the
  join while it is not running; see `VisionApiWeb.SourceMonitor`.
  """
  use VisionApiWeb, :channel

  alias VisionApiWeb.SourceMonitor

  @impl Phoenix.Channel
  def join("status", _payload, socket),
    do: SourceMonitor.join(socket, VisionCore.Status, &VisionCore.Status.subscribe/0)

  @impl Phoenix.Channel
  def handle_info({:vision_status, snapshot}, socket) do
    push(socket, "status", snapshot)
    {:noreply, socket}
  end

  def handle_info({:DOWN, monitor_reference, :process, _pid, _reason}, socket),
    do: SourceMonitor.handle_down(monitor_reference, socket)
end

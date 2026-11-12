defmodule VisionApiWeb.SegmentationChannel do
  @moduledoc """
  Pushes the segmentation pipeline `<name>`'s results on
  `"segmentation:<name>"`, as `VisionCore.Segmentation.Live` hands them
  on, at most its `:max_hz` a second, each a `"segmentation"` event
  whose binary payload is eight little-endian unsigned 16-bit integers,
  then the label grid:

      frame_width, frame_height, band_x, band_y, band_width, band_height,
      grid_width, grid_height, grid_width * grid_height class ids

  The band is the rectangle of the camera's frame, in its pixels, that
  the grid covers; each class id is one byte, row by row.

  The client pushes `"ack"` once it has drawn a grid, and only then is
  the next one sent, as on `VisionApiWeb.PreviewChannel`: a result that
  comes before replaces the one waiting, so a slow link gets the newest
  grid instead of a backlog.

  On each join, before any grid, it pushes a `"classes"` event,
  `%{labels:, roadClasses:}`, the class names by id and those that count
  as road.

  Stops when the pipeline's `Live` restarts, and refuses the join while
  it is not running, and for a name that is not a configured
  segmentation pipeline's; see `VisionApiWeb.SourceMonitor`.
  """
  # On a unit without the pipeline, the client keeps retrying the refused join; logged, the acks would push everything else out of the log.
  use VisionApiWeb, {:channel, log_join: :debug, log_handle_in: false}

  alias VisionApiWeb.{ConfiguredPipeline, SourceMonitor}
  alias VisionCore.Pipelines
  alias VisionCore.Segmentation.Live

  @impl Phoenix.Channel
  def join("segmentation:" <> name, _payload, socket) do
    case ConfiguredPipeline.fetch(name, :segmentation, VisionCore.Segmentation.Supervisor) do
      {:ok, pipeline} ->
        socket
        |> assign(awaiting_ack: false, waiting: nil)
        |> SourceMonitor.join(Pipelines.server(Live, pipeline), fn -> subscribe(pipeline) end)

      :error ->
        SourceMonitor.unavailable()
    end
  end

  @impl Phoenix.Channel
  def handle_in("ack", _payload, %{assigns: %{waiting: nil}} = socket),
    do: {:noreply, assign(socket, :awaiting_ack, false)}

  def handle_in("ack", _payload, socket),
    do: {:noreply, socket |> assign(:waiting, nil) |> send_grid(socket.assigns.waiting)}

  @impl Phoenix.Channel
  def handle_info(
        {:vision_segmentation, segmentation},
        %{assigns: %{awaiting_ack: true}} = socket
      ),
      do: {:noreply, assign(socket, :waiting, segmentation)}

  def handle_info({:vision_segmentation, segmentation}, socket),
    do: {:noreply, send_grid(socket, segmentation)}

  def handle_info({:vision_segmentation_classes, classes}, socket) do
    push(socket, "classes", %{labels: classes.labels, roadClasses: classes.road_classes})
    {:noreply, socket}
  end

  def handle_info({:DOWN, monitor_reference, :process, _pid, _reason}, socket),
    do: SourceMonitor.handle_down(monitor_reference, socket)

  defp send_grid(socket, segmentation) do
    push(socket, "segmentation", {:binary, payload(segmentation)})
    assign(socket, :awaiting_ack, true)
  end

  # The classes go out before subscribing, so no grid can come first; a rejoin hears them again.
  defp subscribe(name) do
    classes =
      VisionCore.Segmentation.Supervisor.classes(VisionCore.Application.active_config(), name)

    send(self(), {:vision_segmentation_classes, classes})
    Live.subscribe(name)
  end

  defp payload(%{frame: {frame_width, frame_height}, band: {x, y, w, h}} = segmentation) do
    <<frame_width::little-16, frame_height::little-16, x::little-16, y::little-16, w::little-16,
      h::little-16, segmentation.width::little-16, segmentation.height::little-16,
      segmentation.data::binary>>
  end
end

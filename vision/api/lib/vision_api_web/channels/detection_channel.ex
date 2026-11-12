defmodule VisionApiWeb.DetectionChannel do
  @moduledoc """
  Pushes a detection pipeline's results as `"detections"` events, shaped
  by `VisionApiWeb.DetectionJSON`: the `"detections"` channel carries the
  default pipeline's, `"detections:<name>"` the named pipeline `<name>`'s.
  Each stops when its `VisionCore.Detection.Live` restarts, and refuses
  the join while it is not running, as on a unit without that pipeline,
  and for a name that is not a configured named pipeline's; see
  `VisionApiWeb.SourceMonitor`.
  """
  # On a unit without the pipeline, the client keeps retrying the refused join.
  use VisionApiWeb, {:channel, log_join: :debug}

  alias VisionApiWeb.{ConfiguredPipeline, DetectionJSON, SourceMonitor}
  alias VisionCore.{Detection, Pipelines}
  alias VisionCore.Detection.Live

  @default_name :detection

  @impl Phoenix.Channel
  def join("detections", _payload, socket), do: join_pipeline(socket, @default_name)

  def join("detections:" <> name, _payload, socket) do
    case ConfiguredPipeline.fetch(name, :detections, Detection.Supervisor) do
      {:ok, pipeline} -> join_pipeline(socket, pipeline)
      :error -> SourceMonitor.unavailable()
    end
  end

  @impl Phoenix.Channel
  def handle_info({:vision_detections, detections}, socket) do
    push(socket, "detections", DetectionJSON.detections(detections))
    {:noreply, socket}
  end

  def handle_info({:DOWN, monitor_reference, :process, _pid, _reason}, socket),
    do: SourceMonitor.handle_down(monitor_reference, socket)

  defp join_pipeline(socket, name),
    do: SourceMonitor.join(socket, Pipelines.server(Live, name), fn -> Live.subscribe(name) end)
end

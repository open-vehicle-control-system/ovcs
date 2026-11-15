defmodule VisionApiWeb.PreviewChannel do
  @moduledoc """
  Pushes one `VisionCore.Preview` stream as `"frame"` events whose
  binary payload is the JPEG itself. The topic names the stream
  (`VisionCore.Preview.streams/1`): `"preview:<prefix>/left"`,
  `"preview:<prefix>/right"` and `"preview:<prefix>/depth"` for the
  stereo unit's cameras and depth, under its prefix, `stereo` by
  default, or `"preview:<name>"` for the frames of the unit's camera of
  its own `<name>`; a stream the unit has not is refused.

  The client pushes `"ack"` once it has shown a frame, and only then is
  the next one sent, so a slow link gets the latest frame instead of a
  backlog. The depth video's colour range is the unit's, shared by every
  dashboard and set with `VisionApiWeb.DepthPreviewController`: the depth
  stream pushes it as a `"depth_range"` event, `%{metres: float}`, after
  every join and on every change, whoever makes it. Stops when
  `VisionCore.Preview` restarts, and refuses the join while it is not
  running; see `VisionApiWeb.SourceMonitor`.
  """
  # The client acks every frame it shows: logged, the acks would push everything else out of the log.
  use VisionApiWeb, {:channel, log_handle_in: false}

  alias VisionApiWeb.{PreviewJSON, SourceMonitor}

  @impl Phoenix.Channel
  def join("preview:" <> stream, _payload, socket) do
    config = VisionCore.Application.active_config() || %VisionCore.Config{}

    if stream in VisionCore.Preview.streams(config) do
      subscribe =
        if stream == VisionCore.Preview.depth_stream(config),
          do: fn -> subscribe_depth(stream) end,
          else: fn -> VisionCore.Preview.subscribe(stream) end

      socket
      |> assign(:stream, stream)
      |> SourceMonitor.join(VisionCore.Preview, subscribe)
    else
      {:error, %{reason: "unknown stream"}}
    end
  end

  @impl Phoenix.Channel
  def handle_in("ack", _payload, socket) do
    VisionCore.Preview.ack(socket.assigns.stream)
    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket), do: VisionApiWeb.UnknownEvent.refuse(socket)

  @impl Phoenix.Channel
  def handle_info({:vision_preview, _stream, jpeg}, socket) do
    push(socket, "frame", {:binary, jpeg})
    {:noreply, socket}
  end

  def handle_info({:vision_preview_options, options}, socket) do
    push(socket, "depth_range", PreviewJSON.depth_range(options))
    {:noreply, socket}
  end

  def handle_info({:DOWN, monitor_reference, :process, _pid, _reason}, socket),
    do: SourceMonitor.handle_down(monitor_reference, socket)

  # Every join hears the range in force, as after a change: a client rejoining may have missed one.
  defp subscribe_depth(stream) do
    :ok = VisionCore.Preview.subscribe(stream)
    send(self(), {:vision_preview_options, VisionCore.Preview.options()})
    :ok
  end
end

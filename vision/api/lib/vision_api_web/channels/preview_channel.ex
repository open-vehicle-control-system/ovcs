defmodule VisionApiWeb.PreviewChannel do
  @moduledoc """
  Pushes one `VisionCore.Preview` stream as `"frame"` events whose
  binary payload is the JPEG itself. The topic names the stream:
  `"preview:left"`, `"preview:right"`, `"preview:depth"` or
  `"preview:<name>"` for the frames of the unit's camera of its own
  `<name>`; a name that is none of the unit's cameras is refused.

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

  @stereo_streams %{"left" => :left, "right" => :right, "depth" => :depth}

  @impl Phoenix.Channel
  def join("preview:" <> stream_name, _payload, socket) do
    case stream(stream_name) do
      {:ok, stream} ->
        socket
        |> assign(:stream, stream)
        |> SourceMonitor.join(VisionCore.Preview, fn -> subscribe(stream) end)

      :error ->
        {:error, %{reason: "unknown stream"}}
    end
  end

  # A name among the configured cameras' atoms, compared as text: a client's topics cannot grow the atom table.
  defp stream(stream_name) do
    case Map.fetch(@stereo_streams, stream_name) do
      {:ok, stream} -> {:ok, stream}
      :error -> camera_stream(stream_name)
    end
  end

  defp camera_stream(stream_name) do
    case VisionCore.Application.active_config() do
      nil ->
        :error

      config ->
        Enum.find_value(VisionCore.Camera.Unit.cameras(config), :error, fn {name, _driver,
                                                                            _server} ->
          if Atom.to_string(name) == stream_name, do: {:ok, name}
        end)
    end
  end

  @impl Phoenix.Channel
  def handle_in("ack", _payload, socket) do
    VisionCore.Preview.ack(socket.assigns.stream)
    {:noreply, socket}
  end

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
  defp subscribe(:depth) do
    :ok = VisionCore.Preview.subscribe(:depth)
    send(self(), {:vision_preview_options, VisionCore.Preview.options()})
    :ok
  end

  defp subscribe(stream), do: VisionCore.Preview.subscribe(stream)
end

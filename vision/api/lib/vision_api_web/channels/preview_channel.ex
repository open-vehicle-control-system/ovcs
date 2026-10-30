defmodule VisionApiWeb.PreviewChannel do
  @moduledoc """
  Pushes one `VisionCore.Preview` stream as `"frame"` events,
  `%{jpeg: base64}`. The topic names the stream: `"preview:left"`,
  `"preview:right"` or `"preview:depth"`.

  The client pushes `"ack"` once it has shown a frame, and only then is
  the next one sent, so a slow link gets the latest frame instead of a
  backlog. On the depth stream it pushes `"depth_range"`, with `"metres"`
  to set the depth video's colour range or without to read it; the reply
  is the range in force, `%{metres: float}`. Stops when `VisionCore.Preview` restarts, and refuses the
  join while it is not running; see `VisionApiWeb.SourceMonitor`.
  """
  use VisionApiWeb, :channel

  alias VisionApiWeb.SourceMonitor

  @streams %{"left" => :left, "right" => :right, "depth" => :depth}

  @impl Phoenix.Channel
  def join("preview:" <> stream_name, _payload, socket) do
    case Map.fetch(@streams, stream_name) do
      {:ok, stream} ->
        socket
        |> assign(:stream, stream)
        |> SourceMonitor.join(VisionCore.Preview, fn -> VisionCore.Preview.subscribe(stream) end)

      :error ->
        {:error, %{reason: "unknown stream"}}
    end
  end

  @impl Phoenix.Channel
  def handle_in("ack", _payload, socket) do
    VisionCore.Preview.ack(socket.assigns.stream)
    {:noreply, socket}
  end

  def handle_in("depth_range", payload, %{assigns: %{stream: :depth}} = socket) do
    reply =
      case Map.fetch(payload, "metres") do
        {:ok, metres} -> VisionCore.Preview.set_options(depth_range_m: metres)
        :error -> {:ok, VisionCore.Preview.options()}
      end

    case reply do
      {:ok, options} -> {:reply, {:ok, %{metres: options.depth_range_m}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("depth_range", _payload, socket),
    do: {:reply, {:error, %{reason: "only the depth stream has a colour range"}}, socket}

  @impl Phoenix.Channel
  def handle_info({:vision_preview, _stream, jpeg}, socket) do
    push(socket, "frame", %{jpeg: Base.encode64(jpeg)})
    {:noreply, socket}
  end

  def handle_info({:DOWN, monitor_reference, :process, _pid, _reason}, socket),
    do: SourceMonitor.handle_down(monitor_reference, socket)
end

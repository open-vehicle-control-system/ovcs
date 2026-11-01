defmodule VisionApiWeb.PreviewChannel do
  @moduledoc """
  Pushes one `VisionCore.Preview` stream as `"frame"` events whose
  binary payload is the JPEG itself. The topic names the stream:
  `"preview:left"`, `"preview:right"` or `"preview:depth"`.

  The client pushes `"ack"` once it has shown a frame, and only then is
  the next one sent, so a slow link gets the latest frame instead of a
  backlog. On the depth stream it pushes `"depth_range"`, with `"metres"`
  to set the depth video's colour range or without to read it; the reply
  is the range in force, `%{metres: float}`. The range is the unit's,
  shared by every dashboard: the depth stream pushes it as a
  `"depth_range"` event, `%{metres: float}`, after every join and on
  every change, whoever makes it. Stops when `VisionCore.Preview`
  restarts, and refuses the join while it is not running; see
  `VisionApiWeb.SourceMonitor`.
  """
  # The client acks every frame it shows: logged, the acks would push everything else out of the log.
  use VisionApiWeb, {:channel, log_handle_in: false}

  alias VisionApiWeb.{DepthRangePresenter, SourceMonitor}

  @streams %{"left" => :left, "right" => :right, "depth" => :depth}

  @impl Phoenix.Channel
  def join("preview:" <> stream_name, _payload, socket) do
    case Map.fetch(@streams, stream_name) do
      {:ok, stream} ->
        socket
        |> assign(:stream, stream)
        |> SourceMonitor.join(VisionCore.Preview, fn -> subscribe(stream) end)

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
      {:ok, options} -> {:reply, {:ok, DepthRangePresenter.present(options)}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("depth_range", _payload, socket),
    do: {:reply, {:error, %{reason: "only the depth stream has a colour range"}}, socket}

  @impl Phoenix.Channel
  def handle_info({:vision_preview, _stream, jpeg}, socket) do
    push(socket, "frame", {:binary, jpeg})
    {:noreply, socket}
  end

  def handle_info({:vision_preview_options, options}, socket) do
    push(socket, "depth_range", DepthRangePresenter.present(options))
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

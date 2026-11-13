defmodule VisionApiWeb.VideoChannel do
  @moduledoc """
  Pushes the video of one of the unit's cameras, from
  `VisionCore.Video`, as `"frame"` events, each a binary payload: a byte
  of flags, bit 0 set on a key frame, the frame's capture time in
  microseconds on the unit's monotonic clock as a little-endian signed
  64-bit integer, its width and height as little-endian unsigned 16-bit
  integers, then the frame of the H.264 stream, its NAL units in Annex B
  form. The detections and segmentation grids carry the same capture
  time, so a client draws them on the frame they were found on. The topic `"video:<name>"` names the
  camera; a camera whose video the unit does not relay is refused. The
  frames come in order from the next key frame.

  The client pushes `"ack"` for each frame it has taken, and only a few
  frames are unacknowledged at once: a slow link skips to a later key
  frame instead of building a backlog. Stops when `VisionCore.Video`
  restarts, and refuses the join while it is not running; see
  `VisionApiWeb.SourceMonitor`.
  """
  # The client acks every frame: logged, the acks would push everything else out of the log.
  use VisionApiWeb, {:channel, log_handle_in: false}

  alias VisionApiWeb.SourceMonitor

  @key_frame_flag 1

  @impl Phoenix.Channel
  def join("video:" <> camera_name, _payload, socket) do
    case camera(camera_name) do
      {:ok, camera} ->
        socket
        |> assign(:camera, camera)
        |> SourceMonitor.join(VisionCore.Video, fn -> VisionCore.Video.subscribe(camera) end)

      :error ->
        {:error, %{reason: "unknown video"}}

      :unavailable ->
        SourceMonitor.unavailable()
    end
  end

  # A name among the relayed cameras' atoms, compared as text: a client's topics cannot grow the atom table.
  defp camera(camera_name) do
    Enum.find_value(VisionCore.Video.videos(), :error, fn {camera, _output} ->
      if Atom.to_string(camera) == camera_name, do: {:ok, camera}
    end)
  catch
    :exit, _reason -> :unavailable
  end

  @impl Phoenix.Channel
  def handle_in("ack", _payload, socket) do
    VisionCore.Video.ack(socket.assigns.camera)
    {:noreply, socket}
  end

  @impl Phoenix.Channel
  def handle_info({:vision_video, _camera, frame}, socket) do
    header =
      <<flags(frame), div(frame.capture_ns, 1_000)::little-signed-64, frame.width::little-16,
        frame.height::little-16>>

    push(socket, "frame", {:binary, header <> frame.h264})
    {:noreply, socket}
  end

  def handle_info({:DOWN, monitor_reference, :process, _pid, _reason}, socket),
    do: SourceMonitor.handle_down(monitor_reference, socket)

  defp flags(%{keyframe?: true}), do: @key_frame_flag
  defp flags(%{keyframe?: false}), do: 0
end

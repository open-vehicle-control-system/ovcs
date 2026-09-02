defmodule RosBridge.Camera.GStreamer do
  @moduledoc """
  Host-dev `RosBridge.Camera` implementation backed by a
  `gst-launch-1.0` Port reading a V4L2 device and emitting MJPEG on
  stdout via `fdsink fd=1`.

  One of two interchangeable host drivers — see also
  `RosBridge.Camera.Ffmpeg`. Both read the same V4L2 devices; pick
  whichever subprocess is on your dev box. GStreamer is idiomatic
  on Linux desktops (and used by most ROS 2 `camera_*` packages
  under the hood); ffmpeg is more permissive with finicky cameras.

  Each instance is registered under a name derived from its
  `:label` so multiple cameras coexist in one BEAM.

  ## Required tooling

  `gst-launch-1.0` must be on `PATH`, along with the v4l2 source
  plugin (typically `gstreamer1.0-plugins-good` on Debian/Ubuntu;
  preinstalled on most desktop Linux distros). The driver crashes
  loudly on init if `gst-launch-1.0` isn't found. The camera must
  also natively output MJPEG at the requested resolution/framerate
  — most UVC webcams and HDMI capture cards do; if yours doesn't,
  swap the `image/jpeg,…` caps for `video/x-raw,…ge ! jpegenc` in
  `pipeline_args/4`.

  ## Framing

  Same `RosBridge.Camera.MjpegStream` splitter as the ffmpeg
  driver — see that module's doc for details.
  """
  @behaviour RosBridge.Camera

  use GenServer
  require Logger

  alias RosBridge.Camera.Frame
  alias RosBridge.Camera.MjpegStream

  def start_link(opts) do
    label = Keyword.fetch!(opts, :label)
    name = name_for(label)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def name_for(label), do: Module.concat([__MODULE__, "L_#{label}"])

  @impl true
  def init(opts) do
    label = Keyword.fetch!(opts, :label)
    device = Keyword.fetch!(opts, :device)
    width = Keyword.get(opts, :width, 1280)
    height = Keyword.get(opts, :height, 720)
    fps = Keyword.get(opts, :fps, 30)

    gst_launch =
      System.find_executable("gst-launch-1.0") ||
        raise "#{__MODULE__}[#{label}]: gst-launch-1.0 not found on PATH"

    args = pipeline_args(device, width, height, fps)

    # Do NOT merge stderr into stdout — gst-launch error prints
    # would corrupt the JPEG byte stream. Stderr is left inherited
    # from the BEAM so errors still surface in the parent's tty.
    port =
      Port.open({:spawn_executable, gst_launch}, [
        :binary,
        :exit_status,
        args: args
      ])

    Logger.info(
      "#{__MODULE__}[#{label}] streaming #{device} at #{width}×#{height}@#{fps} via gst-launch-1.0 pid #{inspect(port)}"
    )

    {:ok,
     %{
       label: label,
       width: width,
       height: height,
       fps: fps,
       device: device,
       port: port,
       buffer: <<>>,
       listeners: []
     }}
  end

  @impl true
  def handle_info({port, {:data, bytes}}, %{port: port} = state) do
    {frames, leftover} = MjpegStream.split(state.buffer <> bytes)

    Enum.each(frames, fn jpeg ->
      frame = %Frame{
        label: state.label,
        width: state.width,
        height: state.height,
        capture_ns: System.monotonic_time(:nanosecond),
        jpeg: jpeg
      }

      Enum.each(state.listeners, &GenServer.cast(&1, {:camera_frame, frame}))
    end)

    {:noreply, %{state | buffer: leftover}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error(
      "#{__MODULE__}[#{state.label}] gst-launch-1.0 exited with status #{status}; terminating driver"
    )

    {:stop, {:gst_launch_exit, status}, state}
  end

  @impl true
  def handle_cast({:register_listener, listener}, state) do
    {:noreply, %{state | listeners: state.listeners ++ [listener]}}
  end

  @impl RosBridge.Camera
  def register_listener(server, listener) do
    GenServer.cast(server, {:register_listener, listener})
  end

  @impl RosBridge.Camera
  def enable(_server), do: :ok

  # `-q` suppresses gst-launch's chatter on stderr; we already merge
  # stderr→stdout via the Port opts so errors still surface, but
  # routine progress prints don't pollute the JPEG byte stream.
  defp pipeline_args(device, width, height, fps) do
    [
      "-q",
      "v4l2src",
      "device=#{device}",
      "!",
      "image/jpeg,width=#{width},height=#{height},framerate=#{fps}/1",
      "!",
      "fdsink",
      "fd=1"
    ]
  end
end

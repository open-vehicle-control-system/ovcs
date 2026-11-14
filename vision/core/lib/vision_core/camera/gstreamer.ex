defmodule VisionCore.Camera.GStreamer do
  @moduledoc """
  Host-dev `VisionCore.Camera` implementation backed by a
  `gst-launch-1.0` Port reading a V4L2 device and emitting MJPEG on
  stdout via `fdsink fd=1`.

  The host driver for USB cameras: GStreamer is idiomatic on Linux
  desktops, and most ROS 2 `camera_*` packages use it under the hood.

  Each instance is registered under a name derived from its
  `:label` so multiple cameras coexist in one BEAM.

  ## Required tooling

  `gst-launch-1.0` must be on `PATH`, along with the v4l2 source
  plugin (typically `gstreamer1.0-plugins-good` on Debian/Ubuntu;
  preinstalled on most desktop Linux distros). The driver crashes
  loudly on init if `gst-launch-1.0` isn't found. The camera must
  also natively output MJPEG at the requested resolution/framerate
  — most UVC webcams and HDMI capture cards do; if yours doesn't,
  swap the `image/jpeg,…` caps for `video/x-raw,… ! jpegenc` in
  `pipeline_arguments/4`.

  ## Framing

  The stream is split into JPEG frames by `VisionCore.Camera.MjpegStream`;
  see that module's doc for details. Each frame carries the `:frame_id`
  the driver was given, `nil` without one.

  ## A pipeline that exits

  When `gst-launch-1.0` exits, as when the camera is unplugged, the
  driver stays up and starts it again after a wait that grows with each
  failure in a row (`VisionCore.Camera.Reopen`, `:reopen_delays_ms`).
  `:executable` names another program to run in its place.
  """
  @behaviour VisionCore.Camera

  use GenServer
  require Logger

  alias VisionCore.Camera.{Frame, MjpegStream, Reopen}
  alias VisionCore.Outputs

  def start_link(opts) do
    label = Keyword.fetch!(opts, :label)
    name = name_for(label)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The registered name of the driver for `label`."
  @impl VisionCore.Camera
  def name_for(label), do: Module.concat([__MODULE__, "L_#{label}"])

  @doc "Whether the capture program runs: `false` while the driver waits to start it again."
  @spec running?(GenServer.server()) :: boolean()
  defdelegate running?(server), to: VisionCore.Camera.Reopen

  @impl GenServer
  def init(opts) do
    label = Keyword.fetch!(opts, :label)
    device = Keyword.fetch!(opts, :device)
    width = Keyword.get(opts, :width, 1280)
    height = Keyword.get(opts, :height, 720)
    fps = Keyword.get(opts, :fps, 30)

    gst_launch =
      Keyword.get(opts, :executable) || System.find_executable("gst-launch-1.0") ||
        raise "#{__MODULE__}[#{label}]: gst-launch-1.0 not found on PATH"

    Logger.info(
      "#{__MODULE__}[#{label}] streaming #{device} at #{width}×#{height}@#{fps} via gst-launch-1.0"
    )

    {:ok,
     open_port(%{
       label: label,
       frame_id: Keyword.get(opts, :frame_id),
       width: width,
       height: height,
       fps: fps,
       device: device,
       program: {gst_launch, pipeline_arguments(device, width, height, fps)},
       port: nil,
       failures: 0,
       reopen_delays_ms: Reopen.delays!(opts),
       buffer: <<>>,
       output: {:camera_frame, name_for(label)}
     })}
  end

  # Stderr stays apart from stdout, where gst-launch's error lines would corrupt the JPEG stream.
  defp open_port(%{program: {gst_launch, arguments}} = state) do
    port = Port.open({:spawn_executable, gst_launch}, [:binary, :exit_status, args: arguments])
    %{state | port: port, buffer: <<>>}
  end

  @impl GenServer
  def handle_call(:running?, _from, state), do: {:reply, state.port != nil, state}

  @impl GenServer
  def handle_info({port, {:data, bytes}}, %{port: port} = state) do
    {frames, leftover} = MjpegStream.split(state.buffer <> bytes)

    Enum.each(frames, fn jpeg ->
      frame = %Frame{
        label: state.label,
        frame_id: state.frame_id,
        width: state.width,
        height: state.height,
        capture_ns: System.monotonic_time(:nanosecond),
        jpeg: jpeg
      }

      Outputs.publish(state.output, {:camera_frame, frame})
    end)

    state = if frames == [], do: state, else: Reopen.delivered(state)
    {:noreply, %{state | buffer: leftover}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error(
      "#{__MODULE__}[#{state.label}] gst-launch-1.0 exited with status #{status}; " <>
        "starting it again in #{Reopen.delay_ms(state)} ms"
    )

    {:noreply, Reopen.closed(state)}
  end

  def handle_info(:reopen, %{port: nil} = state), do: {:noreply, open_port(state)}
  def handle_info(_message, state), do: {:noreply, state}

  # `-q` keeps routine progress off the inherited stderr; errors still print.
  defp pipeline_arguments(device, width, height, fps) do
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

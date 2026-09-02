defmodule RosBridge.Camera.Ffmpeg do
  @moduledoc """
  Host-dev `RosBridge.Camera` implementation backed by an `ffmpeg`
  Port reading a V4L2 device and emitting MJPEG on stdout.

  One of two interchangeable host drivers — see also
  `RosBridge.Camera.GStreamer`. Both read the same V4L2 devices;
  pick whichever subprocess is on your dev box.

  Each instance is registered under a name derived from its
  `:label` so multiple cameras coexist in one BEAM.

  ## Required tooling

  `ffmpeg` must be on `PATH`. On most distros: `apt install ffmpeg`.
  The driver crashes loudly on init if it isn't found.

  ## Framing

  ffmpeg writes a continuous MJPEG stream — concatenated JPEGs back
  to back. `RosBridge.Camera.MjpegStream` splits the byte stream
  into discrete JPEG frames by scanning for `SOI`/`EOI` markers.
  Each frame is tagged with `System.monotonic_time(:nanosecond)`
  at the moment the EOI was seen (driver-side timestamp; close
  enough for host-side visualization, useless for sensor sync).
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

    ffmpeg =
      System.find_executable("ffmpeg") ||
        raise "#{__MODULE__}[#{label}]: ffmpeg not found on PATH"

    args = [
      "-hide_banner",
      "-loglevel",
      "error",
      "-f",
      "v4l2",
      "-framerate",
      Integer.to_string(fps),
      "-video_size",
      "#{width}x#{height}",
      "-i",
      device,
      "-c:v",
      "mjpeg",
      "-f",
      "mjpeg",
      "-"
    ]

    # Do NOT merge stderr into stdout — ffmpeg error prints would
    # corrupt the JPEG byte stream. Stderr is left inherited from
    # the BEAM so errors still surface in the parent's tty.
    port =
      Port.open({:spawn_executable, ffmpeg}, [
        :binary,
        :exit_status,
        args: args
      ])

    Logger.info(
      "#{__MODULE__}[#{label}] streaming #{device} at #{width}×#{height}@#{fps} via ffmpeg pid #{inspect(port)}"
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
      "#{__MODULE__}[#{state.label}] ffmpeg exited with status #{status}; terminating driver"
    )

    {:stop, {:ffmpeg_exit, status}, state}
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
end

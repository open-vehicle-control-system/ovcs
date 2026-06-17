defmodule RosBridge.Camera.LibCamera do
  @moduledoc """
  Target-side `RosBridge.Camera` implementation. Spawns the
  `camera_capture` native binary (one Port per camera), parses its
  length-prefixed framing protocol, and fans frames out to
  registered listeners.

  The native binary lives in `bridges/ros_bridge/priv/` (built via
  `:elixir_make` from `bridges/ros_bridge/c_src/camera_capture/`)
  and owns libcamera + the Pi 5 ISP path. See the c_src README
  there for the wire protocol.

  ## Framing protocol (matches `c_src/camera_capture/framing.h`)

  Each record on the port's stdout is a 4-byte big-endian length
  prefix (set via `Port.open` `{:packet, 4}`), followed by:

      uint8   tag                 # 1 = FRAME
      uint16  width   LE
      uint16  height  LE
      int64   capture_ns LE
      uint32  jpeg_len  LE
      bytes   jpeg

  The Port supervises the binary: closing stdin (which happens
  when this GenServer dies) tells the binary to exit cleanly.
  """
  @behaviour RosBridge.Camera

  use GenServer
  require Logger

  alias RosBridge.Camera.Frame

  @frame_tag 1

  def start_link(opts) do
    label = Keyword.fetch!(opts, :label)
    name = name_for(label)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def name_for(label), do: Module.concat([__MODULE__, "L_#{label}"])

  @impl true
  def init(opts) do
    label = Keyword.fetch!(opts, :label)
    camera_id = Keyword.fetch!(opts, :camera_id)
    width = Keyword.get(opts, :width, 1280)
    height = Keyword.get(opts, :height, 720)
    fps = Keyword.get(opts, :fps, 30)
    rotation = Keyword.get(opts, :rotation, 0)

    executable = binary_path()

    unless File.exists?(executable) do
      raise "#{__MODULE__}[#{label}]: native binary missing at #{executable}; " <>
              "build with `mix compile` on the :rpi5 target (elixir_make)."
    end

    args = [
      "--camera",
      Integer.to_string(camera_id),
      "--width",
      Integer.to_string(width),
      "--height",
      Integer.to_string(height),
      "--fps",
      Integer.to_string(fps),
      "--rotation",
      Integer.to_string(rotation)
    ]

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        {:packet, 4},
        args: args
      ])

    Logger.info(
      "#{__MODULE__}[#{label}] camera #{camera_id} @ #{width}×#{height}/#{fps}fps via #{executable}"
    )

    {:ok,
     %{
       label: label,
       camera_id: camera_id,
       port: port,
       listeners: []
     }}
  end

  @impl true
  def handle_info({port, {:data, packet}}, %{port: port} = state) do
    case parse_record(packet) do
      {:ok, %Frame{} = frame} ->
        frame = %{frame | label: state.label}
        Enum.each(state.listeners, &GenServer.cast(&1, {:camera_frame, frame}))

      {:error, reason} ->
        Logger.warning(
          "#{__MODULE__}[#{state.label}] dropping malformed record: #{inspect(reason)}"
        )
    end

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error(
      "#{__MODULE__}[#{state.label}] camera_capture exited with status #{status}"
    )

    {:stop, {:camera_capture_exit, status}, state}
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

  defp parse_record(<<
         @frame_tag,
         width::little-unsigned-integer-size(16),
         height::little-unsigned-integer-size(16),
         capture_ns::little-signed-integer-size(64),
         jpeg_len::little-unsigned-integer-size(32),
         jpeg::binary-size(jpeg_len)
       >>) do
    {:ok,
     %Frame{
       label: nil,
       width: width,
       height: height,
       capture_ns: capture_ns,
       jpeg: jpeg
     }}
  end

  defp parse_record(_other), do: {:error, :malformed_record}

  # `:code.priv_dir/1` resolves to the consumer's priv (here:
  # ros_bridge's), where elixir_make drops the binary. We keep the
  # native binary in ros_bridge/priv because that's where the
  # build infrastructure already lives — ovcs_drivers stays
  # pure-Elixir.
  defp binary_path do
    case :code.priv_dir(:ros_bridge) do
      {:error, :bad_name} ->
        raise "#{__MODULE__}: :ros_bridge app not loaded; cannot locate camera_capture binary"

      dir ->
        Path.join([List.to_string(dir), "camera_capture"])
    end
  end
end

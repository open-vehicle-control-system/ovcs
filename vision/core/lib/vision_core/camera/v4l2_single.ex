defmodule VisionCore.Camera.V4L2Single do
  @moduledoc """
  `VisionCore.Camera` driver for one colour camera of its own, outside a
  stereo pair, captured over raw V4L2 by `v4l2_capture` in its
  single-camera mode, on a CAMSS board such as the Arduino VENTUNO Q: by
  default a Raspberry Pi HQ Camera (IMX477) in its 2028 × 1520 12-bit
  mode. The `:camera` component (`VisionCore.Components`) starts it.

  Frames are 8-bit RGB (`%Frame{rgb: ...}`), white-balanced by the
  program, at the size `:output` asks for: the sensor mode's own, 2028 ×
  1520 by default, demosaiced bilinearly, or half of it in each axis,
  1014 × 760, each 2x2 Bayer cell one pixel. Each frame's size is the one
  its record gives.

  ## Framing protocol

  Records on the Port's stdout are `{:packet, 4}`:

      uint8   tag                 # 6 = RGB_FRAME
      uint16  width   LE
      uint16  height  LE
      int64   capture_ns LE       # frame start, kernel CLOCK_MONOTONIC
      bytes   rgb                 # width * height * 3, R, G, B

  or the log and metadata records `VisionCore.Camera.V4L2` reads. Records
  the other way, on the program's stdin, change a setting each:
  `name=value`. Closing stdin stops the program.

  ## Settings

  The settings of `control_specs/0`, given in the opts and changed while
  running through `set_controls/2`. Those `VisionCore.Camera.V4L2`
  shares apply as they do to the pair, but `black_level`, a 12-bit
  sample, and the auto exposure, which steers the green channel's mean.
  `awb` balances the white on each frame from the previous one;
  `red_gain` and `blue_gain` apply while it is off.

  ## Opts

    * `:label` (required) — the camera's name as text: the instance
      registers under `name_for/1` of it and labels its frames with it.
    * `:name` — the camera's name, an atom.
    * `:csiphy` (required; `ArgumentError` without) — the CSI PHY the
      sensor is wired to, which `VisionCore.Camera.Camss` routes at the
      sensor size with `:code`.
      Startup waits up to 30 s for the media device and the sensor, which
      register some seconds after boot; a PHY still without a sensor then
      stops the camera with an error naming it.
    * `:sensor_width` (2028), `:sensor_height` (1520) — the sensor mode.
    * `:code` (`"SRGGB12_1X12"`) — the sensor mode's media bus code.
    * `:fps` (15) — the frame rate.
    * `:output` (`:full`) — `:full` for frames of the sensor mode's size,
      `:half` for half of it in each axis; passed as `--output full|half`.
      Another value stops the camera at start, saying so.
    * `:frame_id` — the optical frame each frame carries; `nil` without
      (`VisionCore.Camera.Unit` gives `"<name>_optical"` by default).
    * any setting of `control_specs/0`, by its key.
    * `:stall_timeout_ms` (2000), `:startup_timeout_ms` (15000) — how
      long without a frame, after the last one or after the start, stops
      the camera.
    * `:media_runner` — runs `media-ctl` for the routing, as
      `VisionCore.Camera.Camss.route/2`'s `:runner` (tests).
    * `:executable` — the capture program (default `priv/v4l2_capture`).
  """
  use GenServer
  require Logger

  @behaviour VisionCore.Camera

  alias VisionCore.Camera.{Camss, Frame}
  alias VisionCore.Camera.V4L2.Capture
  alias VisionCore.{Outputs, Timing}

  @rgb_frame_tag 6
  @stall_timeout_ms 2_000
  @startup_timeout_ms 15_000
  # How long CAMSS and the sensor may take to register after the VM starts.
  @media_timeout_ms 30_000
  @default_sensor_width 2028
  @default_sensor_height 1520
  @default_code "SRGGB12_1X12"
  @default_fps 15

  # The pair's settings but its lens's focus, those below changed for a 12-bit colour sensor.
  @colour_overrides %{
    target_brightness: %{description: "Mean green auto exposure steers the image to, 0 to 255"},
    black_level: %{
      range: {0, 4094},
      default: 256,
      description: "Raw 12-bit sample value of black"
    },
    gamma: %{description: "Gamma the image is encoded with"}
  }

  @settings for(
              spec <- VisionCore.Camera.V4L2.control_specs(),
              spec.key != :focus,
              do: Map.merge(spec, Map.get(@colour_overrides, spec.key, %{}))
            )
            |> Kernel.++([
              %{
                key: :awb,
                type: :bool,
                default: true,
                description: "Automatic white balance; off, red_gain and blue_gain apply as set"
              },
              %{
                key: :red_gain,
                type: :double,
                range: {0.5, 4},
                default: 1.0,
                description: "Red channel gain while automatic white balance is off"
              },
              %{
                key: :blue_gain,
                type: :double,
                range: {0.5, 4},
                default: 1.0,
                description: "Blue channel gain while automatic white balance is off"
              }
            ])

  def start_link(opts) do
    label = Keyword.fetch!(opts, :label)
    GenServer.start_link(__MODULE__, opts, name: name_for(label))
  end

  @doc "The registered name of the driver for `label`."
  @impl VisionCore.Camera
  def name_for(label), do: Module.concat([__MODULE__, "L_#{label}"])

  @doc """
  The capture settings: `%{key:, type:, range:, default:, description:}`.
  """
  @impl VisionCore.Camera
  def control_specs, do: @settings

  @impl VisionCore.Camera
  def shared_controls?, do: false

  @impl VisionCore.Camera
  def set_controls(server, controls), do: GenServer.call(server, {:set_controls, controls})

  @impl VisionCore.Camera
  def controls(server), do: GenServer.call(server, :controls)

  @doc """
  The exposure and gain the capture program applies, as
  `VisionCore.Camera.V4L2.live/1` reports them; `nil` before the first
  report.
  """
  @spec live(GenServer.server()) :: map() | nil
  @impl VisionCore.Camera
  def live(server), do: GenServer.call(server, :live)

  @doc false
  def parse_record(
        <<@rgb_frame_tag, width::little-16, height::little-16, kernel_ns::little-signed-64,
          rgb::binary>>
      )
      when byte_size(rgb) == width * height * 3 do
    {:frame,
     %Frame{
       label: nil,
       width: width,
       height: height,
       capture_ns: Timing.monotonic_from_kernel(kernel_ns),
       rgb: rgb
     }}
  end

  def parse_record(<<@rgb_frame_tag, _rest::binary>>), do: {:error, :malformed_record}
  def parse_record(record), do: Capture.parse_record(record)

  @impl GenServer
  def init(opts) do
    label = Keyword.fetch!(opts, :label)
    who = "#{inspect(__MODULE__)}[#{label}]"

    unless Keyword.has_key?(opts, :csiphy),
      do: raise(ArgumentError, "#{who} needs a :csiphy, the CSI PHY its sensor is wired to")

    opts = Capture.accepted(@settings, opts, who)

    state = %{
      label: label,
      who: who,
      frame_id: Keyword.get(opts, :frame_id),
      output: {:camera_frame, name_for(label)},
      controls: Capture.controls(@settings, opts),
      applied: nil
    }

    with {:ok, output} <- output(opts),
         {:ok, nodes} <- route(opts) do
      timeouts = [
        stall_timeout_ms: Keyword.get(opts, :stall_timeout_ms, @stall_timeout_ms),
        startup_timeout_ms: Keyword.get(opts, :startup_timeout_ms, @startup_timeout_ms)
      ]

      arguments = port_arguments(nodes, output, opts)
      {:ok, Map.merge(state, Capture.open(opts, arguments, timeouts, who))}
    else
      {:error, message} ->
        Logger.error("#{who}: #{message}")
        {:stop, message}
    end
  end

  defp output(opts) do
    case Keyword.get(opts, :output, :full) do
      output when output in [:full, :half] -> {:ok, output}
      other -> {:error, ":output is :full or :half, got #{inspect(other)}"}
    end
  end

  # `--video` takes the node's V4L2 name, which the program looks up, not the route's /dev path.
  defp route(opts) do
    csiphy = Keyword.fetch!(opts, :csiphy)

    route_opts =
      [
        width: Keyword.get(opts, :sensor_width, @default_sensor_width),
        height: Keyword.get(opts, :sensor_height, @default_sensor_height),
        code: Keyword.get(opts, :code, @default_code),
        await: @media_timeout_ms
      ] ++ if runner = opts[:media_runner], do: [runner: runner], else: []

    with {:ok, route} <- Camss.route(csiphy, route_opts),
         do: {:ok, [video: "msm_vfe#{csiphy}_video0", sensor: route.sensor]}
  end

  defp port_arguments(nodes, output, opts) do
    [
      "--video",
      nodes[:video],
      "--sensor",
      nodes[:sensor],
      "--sensor-width",
      Integer.to_string(Keyword.get(opts, :sensor_width, @default_sensor_width)),
      "--sensor-height",
      Integer.to_string(Keyword.get(opts, :sensor_height, @default_sensor_height)),
      "--fps",
      Integer.to_string(Keyword.get(opts, :fps, @default_fps)),
      "--output",
      Atom.to_string(output)
    ] ++ Capture.arguments(@settings, opts)
  end

  @impl GenServer
  def handle_call(:controls, _from, state), do: {:reply, state.controls, state}
  def handle_call(:live, _from, state), do: {:reply, state.applied, state}

  def handle_call({:set_controls, controls}, _from, state) do
    case Capture.commands(@settings, controls) do
      {:ok, commands} ->
        Enum.each(commands, &Port.command(state.port, &1))
        updated = Capture.update(@settings, state.controls, controls)
        {:reply, {:ok, updated}, %{state | controls: updated}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_info({port, {:data, packet}}, %{port: port} = state) do
    case parse_record(packet) do
      {:frame, frame} ->
        Outputs.publish(
          state.output,
          {:camera_frame, %{frame | label: state.label, frame_id: state.frame_id}}
        )

        {:noreply, %{state | last_frame_at: Capture.now_ms(), applied: refreshed(state.applied)}}

      {:metadata, metadata} ->
        applied = Map.put(metadata, :received_ms, System.system_time(:millisecond))
        {:noreply, %{state | applied: applied}}

      {:log, level, message} ->
        Logger.log(level, "#{state.who} v4l2_capture: #{message}")
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("#{state.who} dropping malformed record: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("#{state.who} v4l2_capture exited with status #{status}")
    {:stop, {:v4l2_capture_exit, status}, state}
  end

  def handle_info(:watchdog, state), do: Capture.watchdog(state, state.who)
  def handle_info(_message, state), do: {:noreply, state}

  # The program reports only when the exposure changes; frames keep it fresh.
  defp refreshed(nil), do: nil
  defp refreshed(applied), do: %{applied | received_ms: System.system_time(:millisecond)}
end

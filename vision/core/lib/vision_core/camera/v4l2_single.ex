defmodule VisionCore.Camera.V4L2Single do
  @moduledoc """
  `VisionCore.Camera` driver for one colour camera of its own, outside a
  stereo pair, captured over raw V4L2 by `v4l2_capture` in its
  single-camera mode, on a CAMSS board such as the Arduino VENTUNO Q: by
  default a Raspberry Pi HQ Camera (IMX477) in its 2028 × 1520 12-bit
  mode. The `:camera` component (`VisionCore.Components`) starts it.

  Frames are 8-bit RGB (`%Frame{rgb: ...}`), white-balanced by the
  program, one per sent output at every frame (`outputs/1`,
  `VisionCore.Camera.Output`); an output with `send: false` is made by
  the program for those made from it and never leaves it. Its one
  processor, `:cpu`, the program's software conversion, makes the sensor
  mode's size, 2028 × 1520 by default, demosaiced bilinearly, or half of
  it in each axis, 1014 × 760, each 2x2 Bayer cell one pixel; an output
  `:from` another is averaged from it in blocks on the same threads, or
  with `format: :jpeg` encoded from it by the program with libjpeg-turbo
  on a thread of its own, its frames carrying the JPEG (`%Frame{jpeg:
  ...}`), which `VisionCore.Camera.Frame.to_jpeg/2` hands its consumers
  as it is, or with `format: :h264` converted to NV12 and encoded by the
  program on the board's V4L2 video encoder, on a thread of its own, its
  frames carrying the stream's frames (`%Frame{h264: ..., keyframe?:
  ...}`). Each sent output's frames are published under
  `{:camera_frame, name, output}`, `name` the instance's registered name,
  each frame carrying its output's name as its `:output` and the size its
  record gives.

  ## Framing protocol

  Records on the Port's stdout are `{:packet, 4}`:

      uint8   tag                 # 7 = OUTPUT_FRAME
      uint8   output              # the output's index, `VisionCore.Camera.Output`'s
      uint16  width   LE
      uint16  height  LE
      int64   capture_ns LE       # frame start, kernel CLOCK_MONOTONIC
      bytes   rgb                 # width * height * 3, R, G, B

  or, for a JPEG output, the same header under tag 8, OUTPUT_JPEG, then
  the JPEG of the `width` x `height` image, or, for an H.264 output, the
  same header under tag 9, OUTPUT_H264, then a byte of flags, bit 0 set
  on a key frame, then the frame's NAL units in Annex B form; one record
  per sent output per frame, in the order of their indices, or the log
  and metadata records `VisionCore.Camera.V4L2Pair` reads. Records
  the other way, on the program's stdin, change a setting each:
  `name=value`. Closing stdin stops the program.

  ## Settings

  The settings of `control_specs/0`, given in the opts and changed while
  running through `set_controls/2`. Those `VisionCore.Camera.V4L2Pair`
  shares apply as they do to the pair, but `black_level`, a 12-bit
  sample, and the auto exposure, which steers the mean green. `awb`
  balances the white on each frame from the previous one; `red_gain` and
  `blue_gain` apply while it is off. On a sensor with a tuning, the
  IMX477, auto exposure measures the green after lens shading and white
  balance, through the tuning's contrast curve, before the colour matrix
  and the denoise; `ccm` and `denoise` switch its colour correction
  matrix and its chroma denoise, and `gamma` only sets how far auto
  exposure steps, the contrast curve encoding the image. `threads`, 1 to
  8, is how many threads convert each frame and average its outputs, in
  bands of rows: without it, 3 with an output of the sensor mode's size
  made by `:cpu`, 1 otherwise.

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
    * `:outputs` — the camera's named outputs, each `[resolution:
      {width, height}, processor: :cpu]` or `[resolution: {width, height},
      from: output]`, a whole fraction of that output's size, its size by
      default, which `format: :jpeg` and a `:quality` send as a JPEG,
      `format: :h264`, a `:bitrate_kbps` and a `:keyframe_interval` as
      H.264, and `send: false` makes only for the outputs made from it
      (`VisionCore.Camera.Output`); the first sent image output is the
      camera's default. Passed as `--output cpu:<width>x<height>`,
      `--output from:<index>:<width>x<height>`, `--output
      from:<index>:<width>x<height>:jpeg:<quality>` or `--output
      from:<index>:<width>x<height>:h264:<bitrate_kbps>:<keyframe_interval>`,
      in the order of their indices, an unsent one with `:unsent` after
      it. Outputs it cannot make stop the camera at start, saying why;
      the program stops at start on a board without a video encoder.
    * `:output` (`:full`) — the one-output shorthand, without
      `:outputs`: `:full`, the sensor mode's size, or `:half`, half of it
      in each axis, made by `:cpu` and named as the value.
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

  alias VisionCore.Camera.{Camss, Frame, Output}
  alias VisionCore.Camera.V4L2Capture
  alias VisionCore.{Outputs, Timing}

  @output_frame_tag 7
  @output_jpeg_tag 8
  @output_h264_tag 9
  @key_frame_flag 1
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
    gamma: %{
      description:
        "Gamma the image is encoded with and auto exposure steps by; on a sensor with a tuning (IMX477), only the steps"
    }
  }

  @settings for(
              spec <- VisionCore.Camera.V4L2Pair.control_specs(),
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
              },
              %{
                key: :ccm,
                type: :bool,
                default: true,
                description: "Colour correction matrix of the sensor's tuning (IMX477)"
              },
              %{
                key: :denoise,
                type: :bool,
                default: true,
                description:
                  "Chroma denoise against coloured speckle at high gain, on a sensor with a tuning (IMX477)"
              },
              %{
                key: :threads,
                type: :integer,
                range: {1, 8},
                # The outputs decide: `default_threads/2`.
                default: nil,
                description:
                  "Threads converting each frame, 1 to 8; without, 3 with a full-size output and 1 otherwise"
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
  `VisionCore.Camera.V4L2Pair.live/1` reports them; `nil` before the first
  report.
  """
  @spec live(GenServer.server()) :: map() | nil
  @impl VisionCore.Camera
  def live(server), do: GenServer.call(server, :live)

  @doc false
  def parse_record(
        <<@output_frame_tag, output, width::little-16, height::little-16,
          kernel_ns::little-signed-64, rgb::binary>>
      )
      when byte_size(rgb) == width * height * 3 do
    {:frame, output,
     %Frame{
       label: nil,
       width: width,
       height: height,
       capture_ns: Timing.monotonic_from_kernel(kernel_ns),
       rgb: rgb
     }}
  end

  def parse_record(
        <<@output_jpeg_tag, output, width::little-16, height::little-16,
          kernel_ns::little-signed-64, jpeg::binary>>
      )
      when byte_size(jpeg) > 0 do
    {:frame, output,
     %Frame{
       label: nil,
       width: width,
       height: height,
       capture_ns: Timing.monotonic_from_kernel(kernel_ns),
       jpeg: jpeg
     }}
  end

  def parse_record(
        <<@output_h264_tag, output, width::little-16, height::little-16,
          kernel_ns::little-signed-64, flags, h264::binary>>
      )
      when byte_size(h264) > 0 do
    {:frame, output,
     %Frame{
       label: nil,
       width: width,
       height: height,
       capture_ns: Timing.monotonic_from_kernel(kernel_ns),
       h264: h264,
       keyframe?: Bitwise.band(flags, @key_frame_flag) != 0
     }}
  end

  def parse_record(<<tag, _rest::binary>>)
      when tag in [@output_frame_tag, @output_jpeg_tag, @output_h264_tag],
      do: {:error, :malformed_record}

  def parse_record(record), do: V4L2Capture.parse_record(record)

  @impl GenServer
  def init(opts) do
    label = Keyword.fetch!(opts, :label)
    who = "#{inspect(__MODULE__)}[#{label}]"

    unless Keyword.has_key?(opts, :csiphy),
      do: raise(ArgumentError, "#{who} needs a :csiphy, the CSI PHY its sensor is wired to")

    opts = V4L2Capture.accepted(@settings, opts, who)

    state = %{
      label: label,
      who: who,
      frame_id: Keyword.get(opts, :frame_id),
      applied: nil
    }

    with {:ok, outputs} <- outputs(opts),
         opts = Keyword.put_new(opts, :threads, default_threads(outputs, opts)),
         {:ok, nodes} <- route(opts) do
      timeouts = [
        stall_timeout_ms: Keyword.get(opts, :stall_timeout_ms, @stall_timeout_ms),
        startup_timeout_ms: Keyword.get(opts, :startup_timeout_ms, @startup_timeout_ms)
      ]

      arguments = port_arguments(nodes, outputs, opts)

      state =
        Map.merge(state, %{
          controls: V4L2Capture.controls(@settings, opts),
          outputs:
            Map.new(Output.sent(outputs), &{&1.index, {output_key(label, &1.name), &1.name}})
        })

      {:ok, Map.merge(state, V4L2Capture.open(opts, arguments, timeouts, who))}
    else
      {:error, message} ->
        Logger.error("#{who}: #{message}")
        {:stop, message}
    end
  end

  @doc """
  The camera's outputs from `opts`: its `:outputs`, or the one output
  `:output` names, `:full` by default; `{:error, message}` for outputs it
  cannot make (`VisionCore.Camera.Output.resolve/3`). Its one processor,
  `:cpu`, makes the sensor mode's size or half of it; it sends RGB, JPEG
  and H.264 outputs.
  """
  @impl VisionCore.Camera
  def outputs(opts) do
    case {Keyword.fetch(opts, :outputs), Keyword.get(opts, :output, :full)} do
      {{:ok, outputs}, _output} ->
        if Keyword.has_key?(opts, :output),
          do: {:error, ":output is the shorthand of one output: give :outputs or :output"},
          else: Output.resolve(outputs, processors(opts), formats: [:rgb, :jpeg, :h264])

      {:error, output} when output in [:full, :half] ->
        Output.resolve(
          [{output, [resolution: shorthand_size(output, opts), processor: :cpu]}],
          processors(opts)
        )

      {:error, other} ->
        {:error, ":output is :full or :half, got #{inspect(other)}"}
    end
  end

  defp processors(opts), do: %{cpu: [shorthand_size(:full, opts), shorthand_size(:half, opts)]}

  defp shorthand_size(output, opts) do
    divisor = if output == :half, do: 2, else: 1

    {div(Keyword.get(opts, :sensor_width, @default_sensor_width), divisor),
     div(Keyword.get(opts, :sensor_height, @default_sensor_height), divisor)}
  end

  defp output_key(label, output), do: {:camera_frame, name_for(label), output}

  # A frame of the sensor mode's size takes several cores to keep up with the sensor.
  defp default_threads(outputs, opts) do
    full = shorthand_size(:full, opts)

    if Enum.any?(outputs, &(&1.processor == :cpu and {&1.width, &1.height} == full)),
      do: 3,
      else: 1
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

  defp port_arguments(nodes, outputs, opts) do
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
      Integer.to_string(Keyword.get(opts, :fps, @default_fps))
    ] ++ output_arguments(outputs) ++ V4L2Capture.arguments(@settings, opts)
  end

  defp output_arguments(outputs) do
    indices = Map.new(outputs, &{&1.name, &1.index})

    Enum.flat_map(Output.port_order(outputs), fn output ->
      ["--output", output_argument(output, indices) <> if(output.send, do: "", else: ":unsent")]
    end)
  end

  defp output_argument(%Output{processor: :cpu} = output, _indices),
    do: "cpu:#{output.width}x#{output.height}"

  defp output_argument(%Output{from: from, format: :jpeg} = output, indices),
    do: "from:#{indices[from]}:#{output.width}x#{output.height}:jpeg:#{output.quality}"

  defp output_argument(%Output{from: from, format: :h264} = output, indices),
    do:
      "from:#{indices[from]}:#{output.width}x#{output.height}:h264:" <>
        "#{output.bitrate_kbps}:#{output.keyframe_interval}"

  defp output_argument(%Output{from: from} = output, indices),
    do: "from:#{indices[from]}:#{output.width}x#{output.height}"

  @impl GenServer
  def handle_call(:controls, _from, state), do: {:reply, state.controls, state}
  def handle_call(:live, _from, state), do: {:reply, state.applied, state}

  def handle_call({:set_controls, controls}, _from, state) do
    case V4L2Capture.commands(@settings, controls) do
      {:ok, commands} ->
        Enum.each(commands, &Port.command(state.port, &1))
        updated = V4L2Capture.update(@settings, state.controls, controls)
        {:reply, {:ok, updated}, %{state | controls: updated}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_info({port, {:data, packet}}, %{port: port} = state) do
    case parse_record(packet) do
      {:frame, index, frame} ->
        {key, output} = Map.fetch!(state.outputs, index)

        Outputs.publish(
          key,
          {:camera_frame, %{frame | label: state.label, frame_id: state.frame_id, output: output}}
        )

        {:noreply,
         %{state | last_frame_at: V4L2Capture.now_ms(), applied: refreshed(state.applied)}}

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

  def handle_info(:watchdog, state), do: V4L2Capture.watchdog(state, state.who)
  def handle_info(_message, state), do: {:noreply, state}

  # The program reports only when the exposure changes; frames keep it fresh.
  defp refreshed(nil), do: nil
  defp refreshed(applied), do: %{applied | received_ms: System.system_time(:millisecond)}
end

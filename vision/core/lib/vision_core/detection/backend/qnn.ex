defmodule VisionCore.Detection.Backend.Qnn do
  @moduledoc """
  Owns the `qnn_detect` Port: YOLOX on a Qualcomm Hexagon NPU through
  QNN, as on the Arduino VENTUNO Q, one inference in flight at a time.

  The model is a DLC. Its context binary, tied to the chip and the QAIRT
  version, is generated on the board the first time and cached
  (`VisionCore.Detection.QnnContext`); the Port opens once it is there,
  after `init/1`, so a first boot's generation does not hold up the
  vision core.

  The contract is `VisionCore.Detection.Backend`'s, as
  `VisionCore.Detection.Backend.Hailo` meets it: `detect/3` hands a
  frame over or answers `{:error, :busy}` while one is in flight, the
  caller receives `{:inference_detections, sequence, detections}` in the
  submitted image's pixels, and a missing DLC, QAIRT or binary leaves
  the process alive answering `{:error, :unavailable}`. When `qnn_detect`
  exits or leaves a frame unanswered for `:infer_timeout_ms`, the frame in
  flight is answered with `nil` detections and the Port is reopened after
  a wait that grows with each failure in a row.

  ## Options

    * `:dlc_path` — the model (required).
    * `:score_threshold` (`0.4`) — the lowest score `qnn_detect` reports.
    * `:qairt_dir` (`"/opt/qairt"`) — QAIRT's runtime, as the firmware's
      overlay installs it.
    * `:dsp_library_path` (`"/usr/share/qcom/qcs8300/Arduino/Monza/dsp/cdsp"`)
      — the board's DSP libraries.
    * `:name` (the module) — the name it registers under.
    * `:pipeline` (`:detection`) — the detection pipeline whose inference
      step it declares.
    * `:cache_dir` (`"/data/vision/qnn"`, `"/data/vision/qnn/<pipeline>"`
      for a pipeline other than `:detection`) — where the context binary
      is kept. `VisionCore.Detection.QnnContext` removes every other
      binary in it, so two pipelines never share one.
    * `:executable` — the program (default `priv/qnn_detect`).
    * `:infer_timeout_ms` (`2000`), `:reopen_delays_ms`
      (`[1000, 2000, 5000, 10000, 30000]`, the last repeated).
  """
  use GenServer

  @behaviour VisionCore.Detection.Backend

  require Logger

  alias VisionCore.Detection.{Pipeline, QnnContext}
  alias VisionCore.Stereo.Parameters

  # Port protocol tags; must match `qnn_detect`.
  @detect_request_tag 1
  @detections_reply_tag 1
  @log_tag 2

  @default_score_threshold 0.4
  @explanation "Runs object detection on the Hexagon NPU. It finds people, vehicles, " <>
                 "animals and everyday objects, the 80 COCO classes, each as a box with a score. " <>
                 "The model and score_threshold, the lowest score the NPU reports, are fixed in " <>
                 "the build. When the NPU is not ready, inference waits and starts again, and " <>
                 "the depth carries on without it."

  # Detects a wedged Port; not a latency budget.
  @default_infer_timeout_ms 2_000
  @default_reopen_delays_ms [1_000, 2_000, 5_000, 10_000, 30_000]

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Submit a `u8` `{height, width}` (or `{height, width, 3}` RGB) tensor
  for detection: `:ok` when handed to the NPU, `{:error, :busy}` while a
  frame is in flight, `{:error, :unavailable}` without a Port.
  """
  @impl VisionCore.Detection.Backend
  def detect(server \\ __MODULE__, sequence, image) do
    GenServer.call(server, {:detect, sequence, image, self()})
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Whether the Port is open, an inference in flight or not."
  @impl VisionCore.Detection.Backend
  def available?(server \\ __MODULE__) do
    GenServer.call(server, :available?)
  catch
    :exit, _ -> false
  end

  @doc """
  The sum and the count of the inference times `qnn_detect` reported since the
  last call, in microseconds, which this starts again; `nil` until it has
  reported one since the Port last opened, and when the backend is gone.
  """
  @impl VisionCore.Detection.Backend
  def inference_times(server \\ __MODULE__) do
    GenServer.call(server, :inference_times)
  catch
    :exit, _ -> nil
  end

  @impl VisionCore.Detection.Backend
  def npu_kind, do: "Hexagon"

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    pipeline = Keyword.get(opts, :pipeline, :detection)

    state = %{
      port: nil,
      pipeline: pipeline,
      dlc_path: Keyword.fetch!(opts, :dlc_path),
      score_threshold: Keyword.get(opts, :score_threshold, @default_score_threshold),
      qairt_dir: Keyword.get(opts, :qairt_dir, "/opt/qairt"),
      dsp_library_path:
        Keyword.get(opts, :dsp_library_path, "/usr/share/qcom/qcs8300/Arduino/Monza/dsp/cdsp"),
      cache_dir: Keyword.get_lazy(opts, :cache_dir, fn -> default_cache_dir(pipeline) end),
      executable: Keyword.get_lazy(opts, :executable, &default_executable_path/0),
      infer_timeout_ms: Keyword.get(opts, :infer_timeout_ms, @default_infer_timeout_ms),
      reopen_delays_ms: Keyword.get(opts, :reopen_delays_ms, @default_reopen_delays_ms),
      failures: 0,
      inflight: nil,
      times: nil
    }

    if Process.whereis(VisionCore.Parameters),
      do: :ok = VisionCore.Parameters.declare([inference_group(state)])

    {:ok, state, {:continue, :open}}
  end

  defp label(%{pipeline: :detection}), do: inspect(__MODULE__)
  defp label(%{pipeline: pipeline}), do: "#{inspect(__MODULE__)} (#{pipeline})"

  defp inference_group(state) do
    Pipeline.inference_group(state.pipeline, %{
      summary: "Finds objects in the image on the Hexagon NPU.",
      explanation: @explanation,
      compute: %{runs_on: :npu, implementation: :rust, backend: nil},
      parameters: [
        Parameters.build_parameter(
          {:model, Path.basename(state.dlc_path)},
          "The model the NPU runs"
        ),
        Parameters.build_parameter(
          {:score_threshold, state.score_threshold},
          "Lowest score the NPU reports"
        )
      ]
    })
  end

  @impl GenServer
  def handle_continue(:open, state) do
    case open_port(state) do
      {:ok, port} ->
        Logger.info(
          "#{label(state)} loaded #{Path.basename(state.dlc_path)} (score >= #{state.score_threshold})"
        )

        {:noreply, %{state | port: port}}

      {:error, reason} ->
        Logger.error(
          "#{label(state)} unavailable: #{inspect(reason)}. The stereo pipeline " <>
            "continues; no detections will be published."
        )

        {:noreply, state}
    end
  end

  defp open_port(state) do
    context_opts = Map.take(state, [:qairt_dir, :dsp_library_path, :cache_dir]) |> Keyword.new()

    with true <- File.exists?(state.executable) || {:error, {:missing_binary, state.executable}},
         {:ok, binary} <- QnnContext.ensure(state.dlc_path, context_opts) do
      spawn_detector_port(state, binary)
    end
  end

  defp spawn_detector_port(state, binary) do
    env =
      for {name, value} <- QnnContext.env(state.qairt_dir, state.dsp_library_path),
          do: {String.to_charlist(name), String.to_charlist(value)}

    port =
      Port.open({:spawn_executable, state.executable}, [
        :binary,
        :exit_status,
        {:packet, 4},
        {:env, env},
        {:args, [binary, to_string(state.score_threshold)]}
      ])

    {:ok, port}
  rescue
    error -> {:error, error}
  end

  # Answers the frame in flight with no detections and reopens the Port after the next wait.
  defp port_down(state) do
    if inflight = state.inflight do
      Process.cancel_timer(inflight.timer)
      send(inflight.reply_to, {:inference_detections, inflight.sequence, nil})
    end

    delay_ms = Enum.at(state.reopen_delays_ms, state.failures, List.last(state.reopen_delays_ms))
    Process.send_after(self(), :reopen, delay_ms)
    %{state | port: nil, inflight: nil, times: nil, failures: state.failures + 1}
  end

  @impl GenServer
  def handle_call(:available?, _from, state), do: {:reply, not is_nil(state.port), state}

  def handle_call(:inference_times, _from, state), do: take_times(state)

  def handle_call({:detect, _sequence, _image, _reply_to}, _from, %{port: nil} = state),
    do: {:reply, {:error, :unavailable}, state}

  def handle_call({:detect, _sequence, _image, _reply_to}, _from, %{inflight: inflight} = state)
      when not is_nil(inflight),
      do: {:reply, {:error, :busy}, state}

  def handle_call({:detect, sequence, image, reply_to}, _from, state) do
    {height, width, channels} = image_shape(image)

    Port.command(
      state.port,
      <<@detect_request_tag, sequence::little-32, width::little-16, height::little-16, channels,
        Nx.to_binary(image)::binary>>
    )

    timer = Process.send_after(self(), {:infer_timeout, sequence}, state.infer_timeout_ms)
    {:reply, :ok, %{state | inflight: %{sequence: sequence, reply_to: reply_to, timer: timer}}}
  end

  @impl GenServer
  def handle_info({port, {:data, <<@log_tag, level, message::binary>>}}, %{port: port} = state) do
    Logger.log(log_level(level), "#{label(state)} qnn_detect: #{message}")
    {:noreply, state}
  end

  def handle_info({port, {:data, packet}}, %{port: port} = state) do
    case parse_detections(packet) do
      {:ok, sequence, detections, time_us} ->
        {:noreply, deliver(state, sequence, detections, time_us)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:infer_timeout, sequence}, %{inflight: %{sequence: sequence}} = state) do
    Logger.warning(
      "#{label(state)} frame #{sequence} not answered in #{state.infer_timeout_ms} ms; " <>
        "restarting qnn_detect"
    )

    Port.close(state.port)
    {:noreply, port_down(state)}
  end

  def handle_info({:infer_timeout, _stale_sequence}, state), do: {:noreply, state}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("#{label(state)} qnn_detect exited with status #{status}")
    {:noreply, port_down(state)}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.error("#{label(state)} Port died: #{inspect(reason)}")
    {:noreply, port_down(state)}
  end

  def handle_info(:reopen, state), do: handle_continue(:open, state)

  def handle_info(_message, state), do: {:noreply, state}

  defp deliver(
         %{inflight: %{sequence: sequence} = inflight} = state,
         sequence,
         detections,
         time_us
       ) do
    Process.cancel_timer(inflight.timer)
    send(inflight.reply_to, {:inference_detections, sequence, detections})
    %{state | inflight: nil, failures: 0, times: add_time(state.times, time_us)}
  end

  # Late reply for a timed-out frame: dropped.
  defp deliver(state, _stale_sequence, _detections, _time_us), do: state

  defp add_time(times, nil), do: times
  defp add_time(nil, time_us), do: %{sum_us: time_us, count: 1}
  defp add_time(times, time_us), do: %{sum_us: times.sum_us + time_us, count: times.count + 1}

  # Once a time has been reported, a window without one is zero, not unknown.
  defp take_times(%{times: nil} = state), do: {:reply, nil, state}
  defp take_times(state), do: {:reply, state.times, %{state | times: %{sum_us: 0, count: 0}}}

  defp parse_detections(
         <<@detections_reply_tag, sequence::little-32, count::little-16, rest::binary>>
       ),
       do: parse_body(sequence, take_detections(rest, count, []))

  defp parse_detections(_packet), do: :error

  # The detections may be followed by the inference time, a `u32` in microseconds.
  defp parse_body(sequence, {detections, <<time_us::little-32, _rest::binary>>}),
    do: {:ok, sequence, detections, time_us}

  defp parse_body(sequence, {detections, _no_time}), do: {:ok, sequence, detections, nil}

  defp take_detections(rest, 0, detections), do: {Enum.reverse(detections), rest}

  defp take_detections(
         <<class_id::little-16, score::little-float-32, x0::little-float-32, y0::little-float-32,
           x1::little-float-32, y1::little-float-32, rest::binary>>,
         count,
         detections
       ) do
    detection = %{class_id: class_id, score: score, x0: x0, y0: y0, x1: x1, y1: y1}
    take_detections(rest, count - 1, [detection | detections])
  end

  defp take_detections(_malformed, _count, detections), do: {Enum.reverse(detections), <<>>}

  defp log_level(0), do: :info
  defp log_level(1), do: :warning
  defp log_level(_level), do: :error

  # A grey image is a 2-tuple shape.
  defp image_shape(image) do
    case Nx.shape(image) do
      {height, width} -> {height, width, 1}
      {height, width, channels} -> {height, width, channels}
    end
  end

  defp default_cache_dir(:detection), do: "/data/vision/qnn"
  defp default_cache_dir(pipeline), do: "/data/vision/qnn/#{pipeline}"

  defp default_executable_path, do: :vision_core |> :code.priv_dir() |> Path.join("qnn_detect")
end

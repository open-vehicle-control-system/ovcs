defmodule VisionCore.Detection.Backend.Hailo do
  @moduledoc """
  Owns the `hailo_detect` Port: one YOLO HEF loaded on the Hailo-8,
  one inference in flight at a time.

  A Port rather than a NIF. An inference blocks `hailo_detect` for
  milliseconds — over the NIF budget by a wide margin, and a
  scheduler hazard — while an OS process blocking is a non-event. It
  also means a Hailo fault kills a process the supervisor restarts,
  not the BEAM, so the stereo depth path survives it.

  ## Backpressure

  `detect/3` is asynchronous and **drops** the frame if inference is
  already running, answering `{:error, :busy}`. That is the right
  behaviour for a live sensor: inference is far faster than the stereo
  frame rate, so a drop means something is badly wrong, and queueing
  frames would only add latency to a measurement whose whole value is
  being current.

  The caller receives `{:inference_detections, sequence, detections}` where
  each detection is

      %{class_id: 0..79, score: 0.0..1.0, x0:, y0:, x1:, y1:}

  in the **submitted image's** pixel coordinates — the Port owns the
  letterbox transform in both directions, so nothing here has to know
  the model's input size.

  ## Failure is not fatal

  A missing binary or HEF is logged and leaves this process alive but
  inference-less, answering `{:error, :unavailable}`. When `hailo_detect`
  exits, as it does when the accelerator is not ready yet or after a
  failed read, or leaves a frame unanswered for `:infer_timeout_ms`, the
  Port is reopened after a wait that grows with each failure in a row
  (`:reopen_delays_ms`), answering `{:error, :unavailable}` meanwhile. A
  detection reply starts the waits over. The stereo pipeline never
  depends on the detector being up.

  ## Options

    * `:hef_path` — the model (required).
    * `:name` (the module) — the name it registers under.
    * `:pipeline` (`:detection`) — the detection pipeline whose inference
      step it declares.
    * `:score_threshold` (`0.4`) — the lowest score `hailo_detect` reports.
    * `:executable` — the program (default `priv/hailo_detect`).
    * `:working_directory` (`"/data"`) — where `hailo_detect` runs;
      libhailort writes its log there.
    * `:library_path` — where libhailort is (default `Hailort.lib_dir/0`).
    * `:infer_timeout_ms` (`2000`), `:reopen_delays_ms`
      (`[1000, 2000, 5000, 10000, 30000]`, the last repeated).
  """
  use GenServer

  @behaviour VisionCore.Detection.Backend

  require Logger

  alias VisionCore.Detection.Pipeline
  alias VisionCore.Stereo.Parameters

  # :hailort is a dependency only on targets that build hailo_detect.
  @compile {:no_warn_undefined, Hailort}

  # Port protocol tags; must match `hailo_detect`.
  @detect_request_tag 1
  @detections_reply_tag 1
  @log_tag 2

  @default_score_threshold 0.4
  @explanation "Runs object detection on the Hailo-8 accelerator. It finds people, vehicles, " <>
                 "animals and everyday objects, the 80 COCO classes, each as a box with a score. " <>
                 "The model and score_threshold, the lowest score the accelerator reports, are " <>
                 "fixed in the build. When the accelerator is not ready, inference waits and " <>
                 "starts again, and the depth carries on without it: Hailo in the top bar shows " <>
                 "its state."

  # Detects a wedged Port; not a latency budget.
  @default_infer_timeout_ms 2_000
  @default_reopen_delays_ms [1_000, 2_000, 5_000, 10_000, 30_000]

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Submit a `u8` `{height, width}` (or `{height, width, 3}` RGB) tensor
  for detection. Returns `:ok` when the frame was handed to the
  accelerator, `{:error, :busy}` when one is already in flight, and
  `{:error, :unavailable}` when the Port never started.
  """
  @impl VisionCore.Detection.Backend
  def detect(server \\ __MODULE__, sequence, image) do
    GenServer.call(server, {:detect, sequence, image, self()})
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Whether the accelerator is loaded and answering, an inference in
  flight or not: at the stereo frame rate there usually is one.
  """
  @impl VisionCore.Detection.Backend
  def available?(server \\ __MODULE__) do
    GenServer.call(server, :available?)
  catch
    :exit, _ -> false
  end

  @doc """
  The sum and the count of the inference times `hailo_detect` reported since the
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
  def npu_kind, do: "Hailo-8"

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    hef_path = Keyword.fetch!(opts, :hef_path)
    score_threshold = Keyword.get(opts, :score_threshold, @default_score_threshold)
    executable = Keyword.get_lazy(opts, :executable, &default_executable_path/0)

    state = %{
      port: nil,
      pipeline: Keyword.get(opts, :pipeline, :detection),
      executable: executable,
      hef_path: hef_path,
      score_threshold: score_threshold,
      working_directory: Keyword.get(opts, :working_directory, "/data"),
      library_path: Keyword.get(opts, :library_path),
      infer_timeout_ms: Keyword.get(opts, :infer_timeout_ms, @default_infer_timeout_ms),
      reopen_delays_ms: Keyword.get(opts, :reopen_delays_ms, @default_reopen_delays_ms),
      failures: 0,
      inflight: nil,
      times: nil,
      dropped: 0
    }

    if Process.whereis(VisionCore.Parameters),
      do: :ok = VisionCore.Parameters.declare([inference_group(state)])

    case open_port(state) do
      {:ok, port} ->
        Logger.info(
          "#{label(state)} loaded #{Path.basename(hef_path)} " <>
            "(score >= #{score_threshold})"
        )

        {:ok, %{state | port: port}}

      {:error, reason} ->
        Logger.error(
          "#{label(state)} unavailable: #{inspect(reason)}. The stereo pipeline " <>
            "continues; no detections will be published."
        )

        {:ok, state}
    end
  end

  defp label(%{pipeline: :detection}), do: inspect(__MODULE__)
  defp label(%{pipeline: pipeline}), do: "#{inspect(__MODULE__)} (#{pipeline})"

  defp inference_group(state) do
    Pipeline.inference_group(state.pipeline, %{
      summary: "Finds objects in the image on the Hailo-8.",
      explanation: @explanation,
      compute: %{runs_on: :npu, implementation: :rust, backend: nil},
      parameters: [
        Parameters.build_parameter(
          {:model, Path.basename(state.hef_path)},
          "The compiled model the accelerator runs"
        ),
        Parameters.build_parameter(
          {:score_threshold, state.score_threshold},
          "Lowest score the accelerator reports"
        )
      ]
    })
  end

  defp open_port(%{executable: executable, hef_path: hef_path} = state) do
    cond do
      not File.exists?(executable) -> {:error, {:missing_binary, executable}}
      not File.exists?(hef_path) -> {:error, {:missing_hef, hef_path}}
      true -> spawn_detector_port(state)
    end
  end

  defp spawn_detector_port(state) do
    port =
      Port.open({:spawn_executable, state.executable}, [
        :binary,
        :exit_status,
        {:packet, 4},
        {:cd, String.to_charlist(state.working_directory)},
        {:env,
         [{~c"LD_LIBRARY_PATH", String.to_charlist(state.library_path || Hailort.lib_dir())}]},
        {:args, [state.hef_path, to_string(state.score_threshold)]}
      ])

    {:ok, port}
  rescue
    error -> {:error, error}
  end

  # Fails the frame in flight and reopens the Port after the next wait.
  defp port_down(state) do
    if state.inflight, do: Process.cancel_timer(state.inflight.timer)
    delay_ms = Enum.at(state.reopen_delays_ms, state.failures, List.last(state.reopen_delays_ms))
    Process.send_after(self(), :reopen, delay_ms)
    %{state | port: nil, inflight: nil, times: nil, failures: state.failures + 1}
  end

  @impl GenServer
  def handle_call(:available?, _from, state) do
    {:reply, not is_nil(state.port), state}
  end

  def handle_call(:inference_times, _from, state), do: take_times(state)

  def handle_call({:detect, _sequence, _image, _reply_to}, _from, %{port: nil} = state) do
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call({:detect, _sequence, _image, _reply_to}, _from, %{inflight: inflight} = state)
      when not is_nil(inflight) do
    {:reply, {:error, :busy}, %{state | dropped: state.dropped + 1}}
  end

  def handle_call({:detect, sequence, image, reply_to}, _from, state) do
    {height, width, channels} = image_shape(image)
    pixels = Nx.to_binary(image)

    Port.command(
      state.port,
      <<@detect_request_tag, sequence::little-32, width::little-16, height::little-16, channels,
        pixels::binary>>
    )

    timer = Process.send_after(self(), {:infer_timeout, sequence}, state.infer_timeout_ms)

    {:reply, :ok,
     %{state | inflight: %{sequence: sequence, reply_to: reply_to, timer: timer, width: width}}}
  end

  @impl GenServer
  def handle_info({port, {:data, <<@log_tag, level, message::binary>>}}, %{port: port} = state) do
    Logger.log(log_level(level), "#{label(state)} hailo_detect: #{message}")
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
        "restarting hailo_detect"
    )

    Port.close(state.port)
    {:noreply, port_down(state)}
  end

  def handle_info({:infer_timeout, _stale_sequence}, state), do: {:noreply, state}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("#{label(state)} hailo_detect exited with status #{status}")
    {:noreply, port_down(state)}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.error("#{label(state)} Port died: #{inspect(reason)}")
    {:noreply, port_down(state)}
  end

  def handle_info(:reopen, state) do
    case open_port(state) do
      {:ok, port} ->
        Logger.info("#{label(state)} reopened hailo_detect")
        {:noreply, %{state | port: port}}

      {:error, reason} ->
        Logger.error("#{label(state)} unavailable: #{inspect(reason)}")
        {:noreply, state}
    end
  end

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
       ) do
    parse_body(sequence, take_detections(rest, count, []))
  end

  defp parse_detections(_packet), do: :error

  # The detections may be followed by the inference time, a `u32` in microseconds.
  defp parse_body(sequence, {detections, <<time_us::little-32, _rest::binary>>}),
    do: {:ok, sequence, detections, time_us}

  defp parse_body(sequence, {detections, _no_time}), do: {:ok, sequence, detections, nil}

  defp log_level(0), do: :info
  defp log_level(1), do: :warning
  defp log_level(_level), do: :error

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

  # A grey image is a 2-tuple shape.
  defp image_shape(image) do
    case Nx.shape(image) do
      {height, width} -> {height, width, 1}
      {height, width, channels} -> {height, width, channels}
    end
  end

  defp default_executable_path do
    :vision_core
    |> :code.priv_dir()
    |> Path.join("hailo_detect")
  end
end

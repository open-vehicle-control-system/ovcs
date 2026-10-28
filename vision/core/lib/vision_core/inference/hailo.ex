defmodule VisionCore.Inference.Hailo do
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

  Every startup failure — missing binary, missing HEF, no
  accelerator — is logged and leaves this process alive but
  inference-less, answering `{:error, :unavailable}`. Raising in
  `init/1` would take down the supervision tree at boot, and a
  perception pipeline that loses stereo depth because a detector could
  not find its model file is a worse outcome than one that simply
  publishes no detections.
  """
  use GenServer

  @behaviour VisionCore.Inference

  require Logger

  # :hailort is a dependency only on targets that build hailo_detect.
  @compile {:no_warn_undefined, Hailort}

  # Port protocol tags; must match `hailo_detect`.
  @detect_request_tag 1
  @detections_reply_tag 1

  @default_score_threshold 0.4

  # Detects a wedged Port; not a latency budget.
  @infer_timeout_ms 2_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Submit a single-channel (or 3-channel BGR) `Evision.Mat` for
  detection. Returns `:ok` when the frame was handed to the
  accelerator, `{:error, :busy}` when one is already in flight, and
  `{:error, :unavailable}` when the Port never started.
  """
  @impl VisionCore.Inference
  def detect(server \\ __MODULE__, sequence, mat) do
    GenServer.call(server, {:detect, sequence, mat, self()})
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Whether the accelerator is loaded and answering.

  Deliberately *not* "and idle". At the stereo frame rate there is
  usually an inference in flight, so an idle-aware answer reads false
  most of the time it is asked — which makes it useless as the health
  check the docs point people at. Use `busy?/1` for the other
  question.
  """
  @impl VisionCore.Inference
  def available?(server \\ __MODULE__) do
    GenServer.call(server, :available?)
  catch
    :exit, _ -> false
  end

  @doc "Whether an inference is in flight right now."
  @impl VisionCore.Inference
  def busy?(server \\ __MODULE__) do
    GenServer.call(server, :busy?)
  catch
    :exit, _ -> false
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    hef_path = Keyword.fetch!(opts, :hef_path)
    score_threshold = Keyword.get(opts, :score_threshold, @default_score_threshold)
    executable = Keyword.get_lazy(opts, :executable, &default_executable_path/0)

    state = %{
      port: nil,
      executable: executable,
      hef_path: hef_path,
      score_threshold: score_threshold,
      inflight: nil,
      dropped: 0
    }

    case open_port(state) do
      {:ok, port} ->
        Logger.info(
          "#{__MODULE__} loaded #{Path.basename(hef_path)} " <>
            "(score >= #{score_threshold})"
        )

        {:ok, %{state | port: port}}

      {:error, reason} ->
        Logger.error(
          "#{__MODULE__} unavailable: #{inspect(reason)}. The stereo pipeline " <>
            "continues; no detections will be published."
        )

        {:ok, state}
    end
  end

  defp open_port(%{executable: executable, hef_path: hef_path, score_threshold: score_threshold}) do
    cond do
      not File.exists?(executable) -> {:error, {:missing_binary, executable}}
      not File.exists?(hef_path) -> {:error, {:missing_hef, hef_path}}
      true -> spawn_detector_port(executable, hef_path, score_threshold)
    end
  end

  defp spawn_detector_port(executable, hef_path, score_threshold) do
    # `cd: "/data"` because libhailort wants somewhere writable for
    # its own log; the rootfs is read-only.
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        {:packet, 4},
        {:cd, ~c"/data"},
        {:env, [{~c"LD_LIBRARY_PATH", String.to_charlist(Hailort.lib_dir())}]},
        {:args, [hef_path, to_string(score_threshold)]}
      ])

    {:ok, port}
  rescue
    error -> {:error, error}
  end

  @impl GenServer
  def handle_call(:available?, _from, state) do
    {:reply, not is_nil(state.port), state}
  end

  def handle_call(:busy?, _from, state) do
    {:reply, not is_nil(state.inflight), state}
  end

  def handle_call({:detect, _sequence, _mat, _reply_to}, _from, %{port: nil} = state) do
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call({:detect, _sequence, _mat, _reply_to}, _from, %{inflight: inflight} = state)
      when not is_nil(inflight) do
    {:reply, {:error, :busy}, %{state | dropped: state.dropped + 1}}
  end

  def handle_call({:detect, sequence, mat, reply_to}, _from, state) do
    {height, width, channels} = mat_shape(mat)
    pixels = Evision.Mat.to_binary(mat)

    Port.command(
      state.port,
      <<@detect_request_tag, sequence::little-32, width::little-16, height::little-16, channels,
        pixels::binary>>
    )

    timer = Process.send_after(self(), {:infer_timeout, sequence}, @infer_timeout_ms)

    {:reply, :ok,
     %{state | inflight: %{sequence: sequence, reply_to: reply_to, timer: timer, width: width}}}
  end

  @impl GenServer
  def handle_info({port, {:data, packet}}, %{port: port} = state) do
    case parse_detections(packet) do
      {:ok, sequence, detections} -> {:noreply, deliver(state, sequence, detections)}
      :error -> {:noreply, state}
    end
  end

  def handle_info({:infer_timeout, sequence}, %{inflight: %{sequence: sequence}} = state) do
    Logger.warning("#{__MODULE__} frame #{sequence} timed out after #{@infer_timeout_ms}ms")
    {:noreply, %{state | inflight: nil}}
  end

  def handle_info({:infer_timeout, _stale_sequence}, state), do: {:noreply, state}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("#{__MODULE__} hailo_detect exited with status #{status}")
    {:stop, {:hailo_detect_exit, status}, %{state | port: nil, inflight: nil}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.error("#{__MODULE__} Port died: #{inspect(reason)}")
    {:stop, {:port_died, reason}, %{state | port: nil, inflight: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp deliver(%{inflight: %{sequence: sequence} = inflight} = state, sequence, detections) do
    Process.cancel_timer(inflight.timer)
    send(inflight.reply_to, {:inference_detections, sequence, detections})
    %{state | inflight: nil}
  end

  # Late reply for a timed-out frame: dropped.
  defp deliver(state, _stale_sequence, _detections), do: state

  defp parse_detections(
         <<@detections_reply_tag, sequence::little-32, count::little-16, rest::binary>>
       ) do
    {:ok, sequence, take_detections(rest, count, [])}
  end

  defp parse_detections(_packet), do: :error

  defp take_detections(_rest, 0, detections), do: Enum.reverse(detections)

  defp take_detections(
         <<class_id::little-16, score::little-float-32, x0::little-float-32, y0::little-float-32,
           x1::little-float-32, y1::little-float-32, rest::binary>>,
         count,
         detections
       ) do
    detection = %{class_id: class_id, score: score, x0: x0, y0: y0, x1: x1, y1: y1}
    take_detections(rest, count - 1, [detection | detections])
  end

  defp take_detections(_malformed, _count, detections), do: Enum.reverse(detections)

  # Single-channel Mats report a 2-tuple shape.
  defp mat_shape(mat) do
    case Evision.Mat.shape(mat) do
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

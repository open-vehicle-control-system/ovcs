defmodule RosBridge.Inference.Hailo do
  @moduledoc """
  Owns the `hailo_detect` Port: one YOLO HEF loaded on the Hailo-8,
  one inference in flight at a time.

  A Port rather than a NIF. `InferVStreams::infer` blocks for
  milliseconds — over the NIF budget by a wide margin, and a
  scheduler hazard — while an OS process blocking is a non-event. It
  also means a Hailo fault kills a process the supervisor restarts,
  not the BEAM, so the stereo depth path survives it.

  ## Backpressure

  `detect/3` is asynchronous and **drops** the frame if inference is
  already running, answering `{:error, :busy}`. That is the right
  behaviour for a live sensor: yolov8n runs at 177 FPS against a
  pipeline producing 15 frames a second, so a drop means something is
  badly wrong, and queueing frames would only add latency to a
  measurement whose whole value is being current.

  The caller receives `{:hailo_detections, seq, detections}` where
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
  perception bridge that loses stereo depth because a detector could
  not find its model file is a worse outcome than one that simply
  publishes no detections.
  """
  use GenServer

  require Logger

  @tag_detect 1
  @tag_detections 1

  @default_score_threshold 0.4

  # Generous next to a 3.3 ms inference: this is the "the Port has
  # wedged" timeout, not a latency budget.
  @infer_timeout_ms 2_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Submit a single-channel (or 3-channel BGR) `Evision.Mat` for
  detection. Returns `:ok` when the frame was handed to the
  accelerator, `{:error, :busy}` when one is already in flight, and
  `{:error, :unavailable}` when the Port never started.
  """
  def detect(server \\ __MODULE__, seq, mat) do
    GenServer.call(server, {:detect, seq, mat, self()})
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
  def available?(server \\ __MODULE__) do
    GenServer.call(server, :available?)
  catch
    :exit, _ -> false
  end

  @doc "Whether an inference is in flight right now."
  def busy?(server \\ __MODULE__) do
    GenServer.call(server, :busy?)
  catch
    :exit, _ -> false
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    hef_path = Keyword.fetch!(opts, :hef_path)
    threshold = Keyword.get(opts, :score_threshold, @default_score_threshold)
    executable = Keyword.get_lazy(opts, :executable, &binary_path/0)

    state = %{
      port: nil,
      executable: executable,
      hef_path: hef_path,
      score_threshold: threshold,
      inflight: nil,
      dropped: 0
    }

    case open_port(state) do
      {:ok, port} ->
        Logger.info(
          "#{__MODULE__} loaded #{Path.basename(hef_path)} " <>
            "(score >= #{threshold})"
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

  defp open_port(%{executable: executable, hef_path: hef_path, score_threshold: threshold}) do
    cond do
      not File.exists?(executable) -> {:error, {:missing_binary, executable}}
      not File.exists?(hef_path) -> {:error, {:missing_hef, hef_path}}
      true -> do_open_port(executable, hef_path, threshold)
    end
  end

  defp do_open_port(executable, hef_path, threshold) do
    # `cd: "/data"` because libhailort wants somewhere writable for
    # its own log; the rootfs is read-only.
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        {:packet, 4},
        {:cd, ~c"/data"},
        {:args, [hef_path, to_string(threshold)]}
      ])

    {:ok, port}
  rescue
    error -> {:error, error}
  end

  @impl true
  def handle_call(:available?, _from, state) do
    {:reply, not is_nil(state.port), state}
  end

  def handle_call(:busy?, _from, state) do
    {:reply, not is_nil(state.inflight), state}
  end

  def handle_call({:detect, _seq, _mat, _reply_to}, _from, %{port: nil} = state) do
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call({:detect, _seq, _mat, _reply_to}, _from, %{inflight: inflight} = state)
      when not is_nil(inflight) do
    {:reply, {:error, :busy}, %{state | dropped: state.dropped + 1}}
  end

  def handle_call({:detect, seq, mat, reply_to}, _from, state) do
    {height, width, channels} = mat_shape(mat)
    pixels = Evision.Mat.to_binary(mat)

    Port.command(
      state.port,
      <<@tag_detect, seq::little-32, width::little-16, height::little-16, channels,
        pixels::binary>>
    )

    timer = Process.send_after(self(), {:infer_timeout, seq}, @infer_timeout_ms)

    {:reply, :ok,
     %{state | inflight: %{seq: seq, reply_to: reply_to, timer: timer, width: width}}}
  end

  @impl true
  def handle_info({port, {:data, packet}}, %{port: port} = state) do
    case parse_detections(packet) do
      {:ok, seq, detections} -> {:noreply, deliver(state, seq, detections)}
      :error -> {:noreply, state}
    end
  end

  def handle_info({:infer_timeout, seq}, %{inflight: %{seq: seq}} = state) do
    Logger.warning("#{__MODULE__} frame #{seq} timed out after #{@infer_timeout_ms}ms")
    {:noreply, %{state | inflight: nil}}
  end

  def handle_info({:infer_timeout, _stale_seq}, state), do: {:noreply, state}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("#{__MODULE__} hailo_detect exited with status #{status}")
    {:stop, {:hailo_detect_exit, status}, %{state | port: nil, inflight: nil}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.error("#{__MODULE__} Port died: #{inspect(reason)}")
    {:stop, {:port_died, reason}, %{state | port: nil, inflight: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp deliver(%{inflight: %{seq: seq} = inflight} = state, seq, detections) do
    Process.cancel_timer(inflight.timer)
    send(inflight.reply_to, {:hailo_detections, seq, detections})
    %{state | inflight: nil}
  end

  # A reply for a sequence we are no longer waiting on — a frame that
  # timed out and then arrived anyway. Dropping it keeps the
  # in-flight slot honest.
  defp deliver(state, _stale_seq, _detections), do: state

  defp parse_detections(<<@tag_detections, seq::little-32, count::little-16, rest::binary>>) do
    {:ok, seq, take_detections(rest, count, [])}
  end

  defp parse_detections(_packet), do: :error

  defp take_detections(_rest, 0, acc), do: Enum.reverse(acc)

  defp take_detections(
         <<class_id::little-16, score::little-float-32, x0::little-float-32, y0::little-float-32,
           x1::little-float-32, y1::little-float-32, rest::binary>>,
         count,
         acc
       ) do
    detection = %{class_id: class_id, score: score, x0: x0, y0: y0, x1: x1, y1: y1}
    take_detections(rest, count - 1, [detection | acc])
  end

  defp take_detections(_malformed, _count, acc), do: Enum.reverse(acc)

  # Single-channel Mats report a 2-tuple shape.
  defp mat_shape(mat) do
    case Evision.Mat.shape(mat) do
      {height, width} -> {height, width, 1}
      {height, width, channels} -> {height, width, channels}
    end
  end

  defp binary_path do
    :ros_bridge
    |> :code.priv_dir()
    |> Path.join("hailo_detect")
  end
end

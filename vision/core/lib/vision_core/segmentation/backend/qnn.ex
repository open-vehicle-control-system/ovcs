defmodule VisionCore.Segmentation.Backend.Qnn do
  @moduledoc """
  Owns the `qnn_segment` Port: a segmentation model on a Qualcomm
  Hexagon NPU through QNN, as on the Arduino VENTUNO Q, one band in
  flight at a time. The Port stretches the band it is sent onto the
  model's input and answers each cell of the model's output grid with
  the class scoring highest.

  The model is a DLC whose context binary is generated on the board the
  first time and cached (`VisionCore.Detection.QnnContext`); the Port
  opens once it is there, after `init/1`. The contract is
  `VisionCore.Segmentation.Backend`'s: `segment/3` hands a band over or
  answers `{:error, :busy}` while one is in flight, the caller receives
  `{:inference_labels, sequence, labels}`, `nil` labels for a band the
  Port could not segment, and a missing DLC, QAIRT or binary leaves the
  process alive answering `{:error, :unavailable}`. When `qnn_segment`
  exits or leaves a band unanswered for `:infer_timeout_ms`, the band in
  flight is answered with `nil` labels and the Port is reopened after a
  wait that grows with each failure in a row, as
  `VisionCore.Detection.Backend.Qnn` does.

  The band goes to the Port as an image of its own whose band is all of
  it, so only its rows go down the pipe.

  ## Options

    * `:dlc_path` — the model (required).
    * `:pipeline` — the segmentation pipeline whose inference step it
      declares (required).
    * `:qairt_dir` (`"/opt/qairt"`) — QAIRT's runtime.
    * `:dsp_library_path` (`"/usr/share/qcom/qcs8300/Arduino/Monza/dsp/cdsp"`)
      — the board's DSP libraries.
    * `:name` (the module) — the name it registers under.
    * `:cache_dir` (`"/data/vision/qnn/<pipeline>"`) — where the context
      binary is kept, which `VisionCore.Detection.QnnContext` keeps alone
      in it.
    * `:executable` — the program (default `priv/qnn_segment`).
    * `:infer_timeout_ms` (`2000`), `:reopen_delays_ms`
      (`[1000, 2000, 5000, 10000, 30000]`, the last repeated).
  """
  use GenServer

  @behaviour VisionCore.Segmentation.Backend

  require Logger

  alias VisionCore.Detection.QnnContext
  alias VisionCore.Stereo.Parameters

  # Port protocol tags; must match `qnn_segment`.
  @segment_tag 7
  @log_tag 2

  @explanation "Classes each part of the image on the Hexagon NPU among the 19 Cityscapes " <>
                 "classes: road, sidewalk, buildings, vegetation, sky, people, vehicles and " <>
                 "the others. The model sees the band of the image the input step picks, " <>
                 "stretched to its input, and gives a class to each cell of its output grid. " <>
                 "The model is fixed in the build. When the NPU is not ready, inference waits " <>
                 "and starts again, and the depth carries on without it."

  # Detects a wedged Port; not a latency budget.
  @default_infer_timeout_ms 2_000
  @default_reopen_delays_ms [1_000, 2_000, 5_000, 10_000, 30_000]

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Submit a band for segmentation: `:ok` when handed to the NPU,
  `{:error, :busy}` while a band is in flight, `{:error, :unavailable}`
  without a Port.
  """
  @impl VisionCore.Segmentation.Backend
  def segment(server \\ __MODULE__, sequence, band) do
    GenServer.call(server, {:segment, sequence, band, self()})
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Whether the Port is open, a band in flight or not."
  @impl VisionCore.Segmentation.Backend
  def available?(server \\ __MODULE__) do
    GenServer.call(server, :available?)
  catch
    :exit, _ -> false
  end

  @doc """
  The sum and the count of the inference times `qnn_segment` reported
  since the last call, in microseconds, which this starts again; `nil`
  until it has reported one since the Port last opened, and when the
  backend is gone.
  """
  @impl VisionCore.Segmentation.Backend
  def inference_times(server \\ __MODULE__) do
    GenServer.call(server, :inference_times)
  catch
    :exit, _ -> nil
  end

  @impl VisionCore.Segmentation.Backend
  def npu_kind, do: "Hexagon"

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    pipeline = Keyword.fetch!(opts, :pipeline)

    state = %{
      port: nil,
      pipeline: pipeline,
      dlc_path: Keyword.fetch!(opts, :dlc_path),
      qairt_dir: Keyword.get(opts, :qairt_dir, "/opt/qairt"),
      dsp_library_path:
        Keyword.get(opts, :dsp_library_path, "/usr/share/qcom/qcs8300/Arduino/Monza/dsp/cdsp"),
      cache_dir: Keyword.get(opts, :cache_dir, "/data/vision/qnn/#{pipeline}"),
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

  defp label(state), do: "#{inspect(__MODULE__)} (#{state.pipeline})"

  defp inference_group(state) do
    VisionCore.Segmentation.inference_group(state.pipeline, %{
      summary: "Classes each part of the image on the Hexagon NPU.",
      explanation: @explanation,
      compute: %{runs_on: :npu, implementation: :rust, backend: nil},
      parameters: [
        Parameters.build_parameter(
          {:model, Path.basename(state.dlc_path)},
          "The model the NPU runs"
        )
      ]
    })
  end

  @impl GenServer
  def handle_continue(:open, state) do
    case open_port(state) do
      {:ok, port} ->
        Logger.info("#{label(state)} loaded #{Path.basename(state.dlc_path)}")
        {:noreply, %{state | port: port}}

      {:error, reason} ->
        Logger.error(
          "#{label(state)} unavailable: #{inspect(reason)}. The stereo pipeline " <>
            "continues; no segmentation will be published."
        )

        {:noreply, state}
    end
  end

  defp open_port(state) do
    context_opts = Map.take(state, [:qairt_dir, :dsp_library_path, :cache_dir]) |> Keyword.new()

    with true <- File.exists?(state.executable) || {:error, {:missing_binary, state.executable}},
         {:ok, binary} <- QnnContext.ensure(state.dlc_path, context_opts) do
      spawn_port(state, binary)
    end
  end

  defp spawn_port(state, binary) do
    env =
      for {name, value} <- QnnContext.env(state.qairt_dir, state.dsp_library_path),
          do: {String.to_charlist(name), String.to_charlist(value)}

    port =
      Port.open({:spawn_executable, state.executable}, [
        :binary,
        :exit_status,
        {:packet, 4},
        {:env, env},
        {:args, [binary]}
      ])

    {:ok, port}
  rescue
    error -> {:error, error}
  end

  # Answers the band in flight with no labels and reopens the Port after the next wait.
  defp port_down(state) do
    if inflight = state.inflight do
      Process.cancel_timer(inflight.timer)
      send(inflight.reply_to, {:inference_labels, inflight.sequence, nil})
    end

    delay_ms = Enum.at(state.reopen_delays_ms, state.failures, List.last(state.reopen_delays_ms))
    Process.send_after(self(), :reopen, delay_ms)
    %{state | port: nil, inflight: nil, times: nil, failures: state.failures + 1}
  end

  @impl GenServer
  def handle_call(:available?, _from, state), do: {:reply, not is_nil(state.port), state}

  def handle_call(:inference_times, _from, %{times: nil} = state), do: {:reply, nil, state}

  # Once a time has been reported, a window without one is zero, not unknown.
  def handle_call(:inference_times, _from, state),
    do: {:reply, state.times, %{state | times: %{sum_us: 0, count: 0}}}

  def handle_call({:segment, _sequence, _band, _reply_to}, _from, %{port: nil} = state),
    do: {:reply, {:error, :unavailable}, state}

  def handle_call({:segment, _sequence, _band, _reply_to}, _from, %{inflight: inflight} = state)
      when not is_nil(inflight),
      do: {:reply, {:error, :busy}, state}

  def handle_call({:segment, sequence, band, reply_to}, _from, state) do
    %{width: width, height: height, rgb: rgb} = band

    Port.command(state.port, [
      <<@segment_tag, sequence::little-32, width::little-16, height::little-16, 3, 0::little-16,
        height::little-16>>,
      rgb
    ])

    timer = Process.send_after(self(), {:infer_timeout, sequence}, state.infer_timeout_ms)
    {:reply, :ok, %{state | inflight: %{sequence: sequence, reply_to: reply_to, timer: timer}}}
  end

  @impl GenServer
  def handle_info({port, {:data, <<@log_tag, level, message::binary>>}}, %{port: port} = state) do
    Logger.log(log_level(level), "#{label(state)} qnn_segment: #{message}")
    {:noreply, state}
  end

  def handle_info({port, {:data, packet}}, %{port: port} = state) do
    case parse_labels(packet) do
      {:ok, sequence, labels, time_us} -> {:noreply, deliver(state, sequence, labels, time_us)}
      :error -> {:noreply, state}
    end
  end

  def handle_info({:infer_timeout, sequence}, %{inflight: %{sequence: sequence}} = state) do
    Logger.warning(
      "#{label(state)} band #{sequence} not answered in #{state.infer_timeout_ms} ms; " <>
        "restarting qnn_segment"
    )

    Port.close(state.port)
    {:noreply, port_down(state)}
  end

  def handle_info({:infer_timeout, _stale_sequence}, state), do: {:noreply, state}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("#{label(state)} qnn_segment exited with status #{status}")
    {:noreply, port_down(state)}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.error("#{label(state)} Port died: #{inspect(reason)}")
    {:noreply, port_down(state)}
  end

  def handle_info(:reopen, state), do: handle_continue(:open, state)

  def handle_info(_message, state), do: {:noreply, state}

  defp deliver(%{inflight: %{sequence: sequence} = inflight} = state, sequence, labels, time_us) do
    Process.cancel_timer(inflight.timer)
    send(inflight.reply_to, {:inference_labels, sequence, labels})
    %{state | inflight: nil, failures: 0, times: add_time(state.times, time_us)}
  end

  # Late reply for a timed-out band: dropped.
  defp deliver(state, _stale_sequence, _labels, _time_us), do: state

  defp add_time(times, nil), do: times
  defp add_time(nil, time_us), do: %{sum_us: time_us, count: 1}
  defp add_time(times, time_us), do: %{sum_us: times.sum_us + time_us, count: times.count + 1}

  # The labels may be followed by the inference time, a `u32` in microseconds.
  defp parse_labels(
         <<@segment_tag, sequence::little-32, width::little-16, height::little-16, rest::binary>>
       ) do
    cells = width * height

    case rest do
      _empty when cells == 0 ->
        {:ok, sequence, nil, nil}

      <<data::binary-size(^cells), time_us::little-32, _rest::binary>> ->
        {:ok, sequence, %{width: width, height: height, data: data}, time_us}

      <<data::binary-size(^cells)>> ->
        {:ok, sequence, %{width: width, height: height, data: data}, nil}

      _short ->
        {:ok, sequence, nil, nil}
    end
  end

  defp parse_labels(_packet), do: :error

  defp log_level(0), do: :info
  defp log_level(1), do: :warning
  defp log_level(_level), do: :error

  defp default_executable_path, do: :vision_core |> :code.priv_dir() |> Path.join("qnn_segment")
end

defmodule VisionCore.Inference.PortBackend do
  @moduledoc """
  An inference backend's Port: a program that loads a model on an
  accelerator and answers one request at a time, each a 4-byte framed
  packet. `VisionCore.Detection.Backend.Hailo`,
  `VisionCore.Detection.Backend.Qnn` and
  `VisionCore.Segmentation.Backend.Qnn` each run one, and say, as its
  callbacks, how their program is started, what a request and a reply
  look like, and what to tell the caller.

  ## One request in flight

  `submit/3` hands an input over, tagged with a sequence number, or
  answers `{:error, :busy}` while one is in flight and
  `{:error, :unavailable}` without a Port. The caller then receives

      {reply_tag, sequence, result}

  once, `result` being `nil` when the Port could not answer: it exited,
  left the request unanswered for `:infer_timeout_ms`, or answered with
  a reply that is cut short. Such a reply, and a packet that is none the
  backend knows, are logged once, until a reply is read again.

  ## Opening, and opening again

  A backend whose model must be prepared first (`c:prepare/1`) does so
  in a task, so it answers `{:error, :unavailable}` meanwhile instead
  of holding its caller: `state/1` is `:starting`. The Port is then
  opened (`c:open/2`): `:running`. When the Port exits or is closed for
  an unanswered request, and when preparing or opening fails, the
  backend tries again after a wait that grows with each failure in a
  row, `:reopen_delays_ms`; an answered request starts the waits over.
  A failure its callbacks call final (`c:final?/1`), such as a missing
  model, is not tried again: `:failed`.

  ## The inference time

  A reply may carry the accelerator's time for it. `inference_times/1`
  hands over their sum and count since it was last called, `nil` until
  the Port has reported one since it last opened.

  ## Options

  The backend's own, which `c:init/1` reads, and:

    * `:name` (the backend's module) — the name it registers under.
    * `:infer_timeout_ms` (`2000`), a positive integer, and
      `:reopen_delays_ms` (`[1000, 2000, 5000, 10000, 30000]`, the last
      repeated), a non-empty list of non-negative integers; another
      value fails the start (`timings!/1`).
  """
  use GenServer

  require Logger

  # Port protocol tag of a log line, the same in every program.
  @log_tag 2

  # Detects a wedged Port; not a latency budget.
  @default_infer_timeout_ms 2_000
  @default_reopen_delays_ms [1_000, 2_000, 5_000, 10_000, 30_000]

  @typedoc "What a backend keeps of its options, as `c:init/1` returns it."
  @type settings :: map()

  @typedoc """
  The words a backend's log lines are made of: `:label`, what starts
  each line; `:program`, its program's name; `:loaded`, what it says
  once the Port is open; `:input`, what a request carries (`"frame"`);
  and `:output`, what the unit goes without while it is unavailable
  (`"detections"`).
  """
  @type wording :: %{
          label: String.t(),
          program: String.t(),
          loaded: String.t(),
          input: String.t(),
          output: String.t()
        }

  @doc "The backend's settings, from its options. Raises on one it cannot run with."
  @callback init(opts :: keyword()) :: settings()

  @doc "The words of the backend's log lines."
  @callback wording(settings()) :: wording()

  @doc "The inference step the backend declares in `VisionCore.Parameters`."
  @callback inference_group(settings()) :: VisionCore.Parameters.group_declaration()

  @doc """
  What the Port is opened on, made ready before each opening, in a task:
  a model compiled for the board, for one. A backend without it opens
  its Port at once.
  """
  @callback prepare(settings()) :: {:ok, prepared :: term()} | {:error, term()}

  @doc "Starts the program, on what `c:prepare/1` made ready, `nil` without it."
  @callback open(settings(), prepared :: term()) :: {:ok, port()} | {:error, term()}

  @doc "Whether a failure to prepare or open stays until the firmware changes."
  @callback final?(reason :: term()) :: boolean()

  @doc "The packet that asks the program for the inference `sequence` on `input`."
  @callback request(sequence :: non_neg_integer(), input :: term()) :: iodata()

  @doc """
  What a packet of the program that is no log line says: the result of
  the inference `sequence` and its time in microseconds, `nil` when it
  carries none; `{:cut_short, sequence}` for a reply shorter than it
  says; `:error` for anything else.
  """
  @callback parse(packet :: binary()) ::
              {:ok, sequence :: non_neg_integer(), result :: term(),
               time_us :: non_neg_integer() | nil}
              | {:cut_short, sequence :: non_neg_integer()}
              | :error

  @doc "The tag of the message a caller receives its result in."
  @callback reply_tag() :: atom()

  @optional_callbacks prepare: 1

  @doc "Starts `backend`'s Port process; see the module doc for `opts`."
  @spec start_link(module(), keyword()) :: GenServer.on_start()
  def start_link(backend, opts),
    do: GenServer.start_link(__MODULE__, {backend, opts}, name: Keyword.get(opts, :name, backend))

  @doc """
  Hands `input` to the Port as the inference `sequence`, whose result
  the calling process receives: `:ok`, `{:error, :busy}` while one is in
  flight, `{:error, :unavailable}` without a Port or a backend.
  """
  @spec submit(GenServer.server(), non_neg_integer(), term()) ::
          :ok | {:error, :busy | :unavailable}
  def submit(server, sequence, input) do
    GenServer.call(server, {:submit, sequence, input, self()})
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Whether the Port is open, a request in flight or not. `false` when the backend is gone."
  @spec available?(GenServer.server()) :: boolean()
  def available?(server), do: state(server) == :running

  @doc """
  `:starting` while what the Port opens on is prepared, `:running` once
  the Port is open, `:failed` otherwise, the backend gone included.
  """
  @spec state(GenServer.server()) :: :starting | :running | :failed
  def state(server) do
    GenServer.call(server, :state)
  catch
    :exit, _ -> :failed
  end

  @doc """
  The sum and the count of the inference times the Port reported since
  the last call, in microseconds, which this starts again; `nil` until
  it has reported one since it last opened, and when the backend is gone.
  """
  @spec inference_times(GenServer.server()) ::
          %{sum_us: non_neg_integer(), count: non_neg_integer()} | nil
  def inference_times(server) do
    GenServer.call(server, :inference_times)
  catch
    :exit, _ -> nil
  end

  @doc "The options every backend with a Port takes beside its own."
  @spec options() :: [atom()]
  def options, do: [:infer_timeout_ms, :reopen_delays_ms]

  @doc """
  `opts`' `:infer_timeout_ms` (`2000`), a positive integer, and
  `:reopen_delays_ms` (`[1000, 2000, 5000, 10000, 30000]`), a non-empty
  list of non-negative integers; raises `ArgumentError` on another value.
  """
  @spec timings!(keyword()) :: {pos_integer(), [non_neg_integer(), ...]}
  def timings!(opts) do
    infer_timeout_ms = Keyword.get(opts, :infer_timeout_ms, @default_infer_timeout_ms)
    reopen_delays_ms = Keyword.get(opts, :reopen_delays_ms, @default_reopen_delays_ms)

    unless is_integer(infer_timeout_ms) and infer_timeout_ms > 0,
      do: refuse!(:infer_timeout_ms, infer_timeout_ms, "a positive integer")

    unless is_list(reopen_delays_ms) and reopen_delays_ms != [] and
             Enum.all?(reopen_delays_ms, &(is_integer(&1) and &1 >= 0)),
           do:
             refuse!(
               :reopen_delays_ms,
               reopen_delays_ms,
               "a non-empty list of non-negative integers"
             )

    {infer_timeout_ms, reopen_delays_ms}
  end

  defp refuse!(key, value, expected),
    do: raise(ArgumentError, "its #{inspect(key)} is #{expected}, got #{inspect(value)}")

  @impl GenServer
  def init({backend, opts}) do
    Process.flag(:trap_exit, true)
    {infer_timeout_ms, reopen_delays_ms} = timings!(opts)
    settings = backend.init(opts)

    state = %{
      backend: backend,
      settings: settings,
      wording: backend.wording(settings),
      infer_timeout_ms: infer_timeout_ms,
      reopen_delays_ms: reopen_delays_ms,
      port: nil,
      # The task preparing what the Port opens on, until it is done.
      opening: nil,
      failures: 0,
      inflight: nil,
      times: nil,
      unreadable_logged: false
    }

    if Process.whereis(VisionCore.Parameters),
      do:
        :ok =
          VisionCore.Parameters.declare([inference_group(backend, settings, infer_timeout_ms)])

    {:ok, start_opening(state)}
  end

  # The backend's step, with the timeout every Port has, fixed at start.
  defp inference_group(backend, settings, infer_timeout_ms) do
    timeout =
      VisionCore.Stereo.Parameters.build_parameter(
        {:infer_timeout_ms, infer_timeout_ms},
        "Longest wait for an inference before the Port is restarted, in ms"
      )

    Map.update!(backend.inference_group(settings), :parameters, &(&1 ++ [timeout]))
  end

  defp start_opening(%{backend: backend, settings: settings} = state) do
    if function_exported?(backend, :prepare, 1),
      do: %{state | opening: Task.async(fn -> backend.prepare(settings) end)},
      else: open_port(state, {:ok, nil})
  end

  defp open_port(state, prepared) do
    with {:ok, prepared} <- prepared,
         {:ok, port} <- state.backend.open(state.settings, prepared) do
      Logger.info("#{state.wording.label} #{state.wording.loaded}")
      %{state | port: port}
    else
      {:error, reason} -> unavailable(state, reason)
    end
  end

  # Tries again after the next wait, unless what is missing stays missing.
  defp unavailable(%{wording: wording} = state, reason) do
    if state.backend.final?(reason) do
      Logger.error(
        "#{wording.label} unavailable: #{inspect(reason)}. The stereo pipeline " <>
          "continues; no #{wording.output} will be published."
      )

      state
    else
      delay_ms = reopen_delay_ms(state)

      Logger.error(
        "#{wording.label} unavailable: #{inspect(reason)}; trying again in #{delay_ms} ms"
      )

      Process.send_after(self(), :reopen, delay_ms)
      %{state | failures: state.failures + 1}
    end
  end

  defp reopen_delay_ms(%{reopen_delays_ms: delays_ms, failures: failures}),
    do: Enum.at(delays_ms, failures, List.last(delays_ms))

  # Answers the request in flight with no result and reopens the Port after the next wait.
  defp port_down(state) do
    state = answer_inflight(state, nil)
    Process.send_after(self(), :reopen, reopen_delay_ms(state))
    %{state | port: nil, times: nil, failures: state.failures + 1}
  end

  defp answer_inflight(%{inflight: nil} = state, _result), do: state

  defp answer_inflight(%{inflight: inflight} = state, result) do
    Process.cancel_timer(inflight.timer)
    send(inflight.reply_to, {state.backend.reply_tag(), inflight.sequence, result})
    %{state | inflight: nil}
  end

  @impl GenServer
  def handle_call(:state, _from, %{port: nil, opening: nil} = state), do: {:reply, :failed, state}
  def handle_call(:state, _from, %{port: nil} = state), do: {:reply, :starting, state}
  def handle_call(:state, _from, state), do: {:reply, :running, state}

  def handle_call(:inference_times, _from, %{times: nil} = state), do: {:reply, nil, state}

  # Once a time has been reported, a window without one is zero, not unknown.
  def handle_call(:inference_times, _from, state),
    do: {:reply, state.times, %{state | times: %{sum_us: 0, count: 0}}}

  def handle_call({:submit, _sequence, _input, _reply_to}, _from, %{port: nil} = state),
    do: {:reply, {:error, :unavailable}, state}

  def handle_call({:submit, _sequence, _input, _reply_to}, _from, %{inflight: inflight} = state)
      when not is_nil(inflight),
      do: {:reply, {:error, :busy}, state}

  def handle_call({:submit, sequence, input, reply_to}, _from, state) do
    Port.command(state.port, state.backend.request(sequence, input))
    timer = Process.send_after(self(), {:infer_timeout, sequence}, state.infer_timeout_ms)
    {:reply, :ok, %{state | inflight: %{sequence: sequence, reply_to: reply_to, timer: timer}}}
  end

  @impl GenServer
  def handle_info({reference, prepared}, %{opening: %Task{ref: reference}} = state) do
    Process.demonitor(reference, [:flush])
    {:noreply, open_port(%{state | opening: nil}, prepared)}
  end

  def handle_info(
        {:DOWN, reference, :process, _pid, reason},
        %{opening: %Task{ref: reference}} = state
      ),
      do: {:noreply, open_port(%{state | opening: nil}, {:error, reason})}

  def handle_info({port, {:data, <<@log_tag, level, message::binary>>}}, %{port: port} = state) do
    Logger.log(log_level(level), "#{state.wording.label} #{state.wording.program}: #{message}")
    {:noreply, state}
  end

  def handle_info({port, {:data, packet}}, %{port: port} = state) do
    case state.backend.parse(packet) do
      {:ok, sequence, result, time_us} ->
        {:noreply, deliver(%{state | unreadable_logged: false}, sequence, result, time_us)}

      {:cut_short, sequence} ->
        {:noreply, state |> note_unreadable("cut short") |> answer_cut_short(sequence)}

      :error ->
        {:noreply, note_unreadable(state, "none it knows")}
    end
  end

  def handle_info({:infer_timeout, sequence}, %{inflight: %{sequence: sequence}} = state) do
    %{wording: wording} = state

    Logger.warning(
      "#{wording.label} #{wording.input} #{sequence} not answered in " <>
        "#{state.infer_timeout_ms} ms; restarting #{wording.program}"
    )

    Port.close(state.port)
    {:noreply, port_down(state)}
  end

  def handle_info({:infer_timeout, _stale_sequence}, state), do: {:noreply, state}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("#{state.wording.label} #{state.wording.program} exited with status #{status}")
    {:noreply, port_down(state)}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.error("#{state.wording.label} Port died: #{inspect(reason)}")
    {:noreply, port_down(state)}
  end

  def handle_info(:reopen, %{port: nil, opening: nil} = state),
    do: {:noreply, start_opening(state)}

  def handle_info(_message, state), do: {:noreply, state}

  defp deliver(%{inflight: %{sequence: sequence}} = state, sequence, result, time_us) do
    state = answer_inflight(state, result)
    %{state | failures: 0, times: add_time(state.times, time_us)}
  end

  # Late reply for a timed-out request: dropped.
  defp deliver(state, _stale_sequence, _result, _time_us), do: state

  defp note_unreadable(%{unreadable_logged: true} = state, _what), do: state

  defp note_unreadable(%{wording: wording} = state, what) do
    Logger.warning("#{wording.label} #{wording.program} sent a packet that is #{what}")
    %{state | unreadable_logged: true}
  end

  defp answer_cut_short(%{inflight: %{sequence: sequence}} = state, sequence),
    do: answer_inflight(state, nil)

  defp answer_cut_short(state, _stale_sequence), do: state

  defp add_time(times, nil), do: times
  defp add_time(nil, time_us), do: %{sum_us: time_us, count: 1}
  defp add_time(times, time_us), do: %{sum_us: times.sum_us + time_us, count: times.count + 1}

  defp log_level(0), do: :info
  defp log_level(1), do: :warning
  defp log_level(_level), do: :error
end

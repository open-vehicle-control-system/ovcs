defmodule VisionCore.Calibration.Session do
  @moduledoc """
  The stereo unit's calibration session: one per unit, shared by every
  dashboard.

  `start/1` begins capturing views of a `VisionCore.Calibration.Board`.
  While at least one process is subscribed (`subscribe/0`), at most
  `:detect_hz` times a second, the session takes the latest left frame
  and the right frame closest to it in capture time, within
  `:pair_tolerance_ms`, and looks for the board in both. Frames arriving
  meanwhile replace each other. A pair where both sides see the board
  becomes a sample when its left view is far enough from every sample
  kept (`VisionCore.Calibration.Coverage.good_sample?/2`). Without a
  subscriber nothing is detected, and the samples stay. A side whose
  detection answers an error, such as a frame that does not decode, is
  logged once, then again only after one of its detections has worked.

  `solve/0`, once the samples are `good_enough`, runs
  `VisionCore.Calibration.Solver` on them. `apply/0` commits the solved
  pair (`VisionCore.Stereo.Calibration.commit/2`) and answers at once:
  the outcome comes as the next state. A commit ends the session, a
  refusal leaves it solved, with the error. `cancel/0` ends the session
  at any point but during an apply, killing a running solve.

  The phases: `:idle`, `:capturing`, `:solving`, `:solved`, `:applying`,
  then `:idle` again. A failed solve goes back to `:capturing`, with the
  error.

  Detection, solve and commit run in tasks under the
  `VisionCore.Calibration.Tasks` `Task.Supervisor`, one at a time, not
  linked to the session: a commit, which may restart the stereo unit,
  outlives whoever asked for it.

  The session takes both cameras' frames from `start/1` until it is idle
  again, and none outside a session. `VisionCore.Outputs` holds the
  subscriptions, keyed by camera name, across the cameras' restarts,
  such as the one a first calibration's commit causes.

  Each subscriber receives `{:calibration_session, state}` on every
  change; a change of the last detection alone, at most `:detect_hz`
  times a second.

  ## Options

    * `:config` (required) — the active `VisionCore.Config`, with the
      `:stereo` component.
    * `:detect_hz` (4) — the most detections a second.
    * `:pair_tolerance_ms` (the `:stereo` component's, else 33) — the
      largest capture time gap of a pair.
    * `:detect` (`VisionCore.Calibration.Chessboard.detect/2`),
      `:solve` (`VisionCore.Calibration.Solver.solve/3`),
      `:commit` (`VisionCore.Stereo.Calibration.commit/2`) — what the
      tasks run.
  """
  use GenServer
  require Logger

  alias VisionCore.Calibration.{Board, Chessboard, Coverage, Solver}
  alias VisionCore.Camera.Frame
  alias VisionCore.Outputs
  alias VisionCore.Stereo.Supervisor, as: StereoSupervisor

  @tasks VisionCore.Calibration.Tasks
  @default_detect_hz 4
  @default_pair_tolerance_ms 33
  @right_frames_kept 4
  @not_running "the stereo cameras are not running"

  @type phase :: :idle | :capturing | :solving | :solved | :applying
  @type fractions :: [{float(), float()}]
  @type state :: %{
          phase: phase(),
          board: Board.t() | nil,
          samples: non_neg_integer(),
          progress: Coverage.params(),
          good_enough: boolean(),
          detection:
            %{left: fractions() | nil, right: fractions() | nil, sample: boolean()} | nil,
          result: Solver.result() | nil,
          error: String.t() | nil
        }

  @doc "Starts the session; see the module doc for `opts`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Sends the calling process `{:calibration_session, state}` on each
  change, until it exits, and answers the state. Detection runs only
  while a process is subscribed.
  """
  @spec subscribe() :: {:ok, state()}
  def subscribe, do: GenServer.call(__MODULE__, :subscribe)

  @doc "Starts capturing views of `board`. Refused while a session runs, or the cameras do not."
  @spec start(Board.t()) :: :ok | {:error, String.t()}
  def start(%Board{} = board), do: GenServer.call(__MODULE__, {:start, board})

  @doc """
  Ends the session, killing a running solve. Refused during an apply:
  killing the commit would skip its restore of the files on a refusal.
  """
  @spec cancel() :: :ok | {:error, String.t()}
  def cancel, do: GenServer.call(__MODULE__, :cancel)

  @doc "Solves for the calibration from the samples. Refused before they are good enough."
  @spec solve() :: :ok | {:error, String.t()}
  def solve, do: GenServer.call(__MODULE__, :solve)

  @doc """
  Commits the solved calibration, answering once it has begun; the
  outcome comes as the next state. Refused before a solve.
  """
  @spec apply() :: :ok | {:error, String.t()}
  def apply, do: GenServer.call(__MODULE__, :apply)

  @doc "The session's state."
  @spec state() :: state()
  def state, do: GenServer.call(__MODULE__, :state)

  @impl GenServer
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    detect_hz = Keyword.get(opts, :detect_hz, @default_detect_hz)

    tolerance_ms =
      Keyword.get_lazy(opts, :pair_tolerance_ms, fn -> unit_pair_tolerance_ms(config) end)

    {:ok,
     Map.merge(
       %{
         config: config,
         cameras: StereoSupervisor.cameras(config),
         frame_keys:
           for({{:camera_frame, _side}, key} <- StereoSupervisor.outputs(config), do: key),
         interval_ms: max(1, round(1_000 / detect_hz)),
         pair_tolerance_ns: tolerance_ms * 1_000_000,
         detect: Keyword.get(opts, :detect, &Chessboard.detect/2),
         solve: Keyword.get(opts, :solve, &Solver.solve/3),
         commit: Keyword.get(opts, :commit, &VisionCore.Stereo.Calibration.commit/2),
         subscribers: %{},
         task: nil,
         tick: nil,
         left: nil,
         rights: [],
         last_broadcast_ms: nil,
         pending_broadcast: nil,
         failing_sides: MapSet.new()
       },
       idle()
     )}
  end

  defp unit_pair_tolerance_ms(%VisionCore.Config{components: components}) do
    case List.keyfind(components, :stereo, 0) do
      {:stereo, opts} when is_list(opts) ->
        Keyword.get(opts, :pair_tolerance_ms, @default_pair_tolerance_ms)

      _no_options ->
        @default_pair_tolerance_ms
    end
  end

  defp idle,
    do: %{
      phase: :idle,
      board: nil,
      samples: [],
      size: nil,
      detection: nil,
      result: nil,
      error: nil
    }

  @impl GenServer
  def handle_call(:subscribe, {pid, _tag}, state) do
    state =
      if pid in Map.values(state.subscribers),
        do: state,
        else: put_in(state.subscribers[Process.monitor(pid)], pid)

    {:reply, {:ok, public(state)}, settle(state)}
  end

  def handle_call({:start, board}, _from, %{phase: :idle} = state) do
    if cameras_running?(state.cameras) do
      for key <- state.frame_keys, do: :ok = Outputs.subscribe(key)
      state = %{state | phase: :capturing, board: board}
      {:reply, :ok, state |> broadcast() |> settle()}
    else
      {:reply, {:error, @not_running}, state}
    end
  end

  def handle_call({:start, _board}, _from, state),
    do: {:reply, {:error, "a calibration session is already running"}, state}

  def handle_call(:cancel, _from, %{phase: :applying} = state),
    do: {:reply, {:error, "the calibration is being applied"}, state}

  def handle_call(:cancel, _from, %{phase: :idle} = state), do: {:reply, :ok, state}

  def handle_call(:cancel, _from, state) do
    state = state |> stop_task() |> end_session()
    {:reply, :ok, state |> broadcast() |> settle()}
  end

  def handle_call(:solve, _from, %{phase: :capturing} = state) do
    if Coverage.good_enough?(sample_parameters(state)) do
      %{solve: solve, board: board, size: size} = state
      samples = for sample <- state.samples, do: Map.take(sample, [:left, :right])
      state = stop_task(state)
      task = Task.Supervisor.async_nolink(@tasks, fn -> solve.(board, size, samples) end)
      state = %{state | phase: :solving, task: {:solve, task}, detection: nil, error: nil}
      {:reply, :ok, state |> broadcast() |> settle()}
    else
      {:reply, {:error, "the samples do not cover enough views of the board yet"}, state}
    end
  end

  def handle_call(:solve, _from, state),
    do: {:reply, {:error, "the session is not capturing"}, state}

  def handle_call(:apply, _from, %{phase: :solved, result: result} = state) do
    %{commit: commit, config: config} = state
    calibrations = %{left: result.left, right: result.right}
    task = Task.Supervisor.async_nolink(@tasks, fn -> commit.(config, calibrations) end)
    state = %{state | phase: :applying, task: {:commit, task}, error: nil}
    {:reply, :ok, broadcast(state)}
  end

  def handle_call(:apply, _from, state),
    do: {:reply, {:error, "there is no solved calibration to apply"}, state}

  def handle_call(:state, _from, state), do: {:reply, public(state), state}

  @impl GenServer
  def handle_cast({:camera_frame, %Frame{} = frame}, state) do
    if detecting?(state),
      do: {:noreply, keep_frame(state, frame)},
      else: {:noreply, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    state = %{state | tick: nil}
    state = if detecting?(state), do: detect(state), else: state
    {:noreply, settle(state)}
  end

  def handle_info({:broadcast, token}, %{pending_broadcast: token} = state),
    do: {:noreply, broadcast(state)}

  def handle_info({ref, outcome}, %{task: {kind, %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | task: nil} |> finished(kind, outcome) |> settle()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: {kind, %Task{ref: ref}}} = state),
    do: {:noreply, %{state | task: nil} |> crashed(kind, reason) |> settle()}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {_pid, subscribers} = Map.pop(state.subscribers, ref)
    {:noreply, settle(%{state | subscribers: subscribers})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp end_session(state) do
    for key <- state.frame_keys, do: :ok = Outputs.unsubscribe(key)
    Map.merge(state, idle())
  end

  defp cameras_running?([]), do: false

  defp cameras_running?(cameras),
    do: Enum.all?(cameras, fn {_driver, name} -> GenServer.whereis(name) != nil end)

  defp detecting?(state), do: state.phase == :capturing and state.subscribers != %{}

  defp keep_frame(state, %Frame{label: "left"} = frame), do: %{state | left: frame}

  defp keep_frame(state, %Frame{label: "right"} = frame),
    do: %{state | rights: Enum.take([frame | state.rights], @right_frames_kept)}

  defp keep_frame(state, _frame), do: state

  # One tick pending while detecting; the frames go once nothing is detected.
  defp settle(state) do
    cond do
      not detecting?(state) -> %{state | left: nil, rights: []}
      state.tick == nil -> %{state | tick: Process.send_after(self(), :tick, state.interval_ms)}
      true -> state
    end
  end

  defp detect(%{task: nil, left: %Frame{} = left} = state) do
    case closest(left, state.rights, state.pair_tolerance_ns) do
      nil ->
        state

      right ->
        %{detect: detect, board: board} = state

        task =
          Task.Supervisor.async_nolink(@tasks, fn -> detect_pair(detect, board, left, right) end)

        %{state | task: {:detect, task}, left: nil}
    end
  end

  defp detect(state), do: state

  defp closest(left, rights, tolerance_ns) do
    rights
    |> Enum.filter(&(abs(&1.capture_ns - left.capture_ns) <= tolerance_ns))
    |> Enum.min_by(&abs(&1.capture_ns - left.capture_ns), fn -> nil end)
  end

  defp detect_pair(detect, board, left, right) do
    left_found = detect.(left, board)
    right_found = detect.(right, board)
    left_corners = corners(left_found)
    right_corners = corners(right_found)
    size = {left.width, left.height}

    parameters =
      if left_corners && right_corners, do: Coverage.parameters(left_corners, board, size)

    %{
      left: left_corners,
      right: right_corners,
      parameters: parameters,
      left_size: size,
      right_size: {right.width, right.height},
      errors: [left: detect_error(left_found), right: detect_error(right_found)]
    }
  end

  defp corners({:ok, corners}), do: corners
  defp corners(_not_found), do: nil

  defp detect_error({:error, reason}), do: reason
  defp detect_error(_detected), do: nil

  defp finished(state, :detect, found) do
    state = log_detect_errors(state, found.errors)

    sample? =
      found.parameters != nil and
        Coverage.good_sample?(found.parameters, sample_parameters(state))

    detection = %{
      left: fractions(found.left, found.left_size),
      right: fractions(found.right, found.right_size),
      sample: sample?
    }

    if sample? do
      sample = %{left: found.left, right: found.right, parameters: found.parameters}

      broadcast(%{
        state
        | samples: state.samples ++ [sample],
          size: state.size || found.left_size,
          detection: detection
      })
    else
      broadcast_detection(%{state | detection: detection})
    end
  end

  defp finished(state, :solve, {:ok, result}),
    do: broadcast(%{state | phase: :solved, result: result})

  defp finished(state, :solve, {:error, message}),
    do: broadcast(%{state | phase: :capturing, error: message})

  defp finished(state, :commit, :ok), do: broadcast(end_session(state))

  defp finished(state, :commit, {:error, message}),
    do: broadcast(%{state | phase: :solved, error: message})

  defp log_detect_errors(state, errors) do
    failing_sides =
      Enum.reduce(errors, state.failing_sides, fn
        {side, nil}, failing_sides ->
          MapSet.delete(failing_sides, side)

        {side, reason}, failing_sides ->
          if not MapSet.member?(failing_sides, side),
            do: Logger.warning("#{__MODULE__} #{side} detection failed: #{inspect(reason)}")

          MapSet.put(failing_sides, side)
      end)

    %{state | failing_sides: failing_sides}
  end

  defp crashed(state, :detect, reason) do
    Logger.warning("#{__MODULE__} detection failed: #{Exception.format_exit(reason)}")
    state
  end

  defp crashed(state, :solve, reason) do
    Logger.error("#{__MODULE__} solve failed: #{Exception.format_exit(reason)}")
    broadcast(%{state | phase: :capturing, error: "the solve failed; the log says why"})
  end

  defp crashed(state, :commit, reason) do
    Logger.error("#{__MODULE__} apply failed: #{Exception.format_exit(reason)}")
    broadcast(%{state | phase: :solved, error: "the apply failed; the log says why"})
  end

  defp stop_task(%{task: nil} = state), do: state

  defp stop_task(%{task: {_kind, task}} = state) do
    Task.shutdown(task, :brutal_kill)
    %{state | task: nil}
  end

  defp fractions(nil, _size), do: nil

  defp fractions(corners, {width, height}),
    do: for({x, y} <- corners, do: {x / width, y / height})

  defp sample_parameters(state), do: Enum.map(state.samples, & &1.parameters)

  defp public(state) do
    parameters = sample_parameters(state)

    %{
      phase: state.phase,
      board: state.board,
      samples: length(state.samples),
      progress: Coverage.progress(parameters),
      good_enough: Coverage.good_enough?(parameters),
      detection: state.detection,
      result: state.result,
      error: state.error
    }
  end

  defp broadcast(state) do
    message = {:calibration_session, public(state)}
    for pid <- Map.values(state.subscribers), do: send(pid, message)

    %{
      state
      | last_broadcast_ms: System.monotonic_time(:millisecond),
        pending_broadcast: nil
    }
  end

  defp broadcast_detection(%{pending_broadcast: nil} = state) do
    wait_ms =
      case state.last_broadcast_ms do
        nil -> 0
        last_ms -> last_ms + state.interval_ms - System.monotonic_time(:millisecond)
      end

    if wait_ms <= 0 do
      broadcast(state)
    else
      token = make_ref()
      Process.send_after(self(), {:broadcast, token}, wait_ms)
      %{state | pending_broadcast: token}
    end
  end

  defp broadcast_detection(state), do: state
end

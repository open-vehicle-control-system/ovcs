defmodule VisionCore.Calibration.Session do
  @moduledoc """
  The unit's calibration session: one per unit, shared by every
  dashboard, on one of its targets at a time (`VisionCore.Calibration`),
  its stereo pair or a camera of its own.

  `start/2` begins capturing views of a `VisionCore.Calibration.Board`
  with a target's cameras. While at least one process is subscribed
  (`subscribe/0`), at most `:detect_hz` times a second, the session looks
  for the board in the target's latest frames: for a stereo pair, the
  latest left frame and the right frame closest to it in capture time,
  within `:pair_tolerance_ms`; for a camera, its latest frame. Frames
  arriving meanwhile replace each other. A detection where every camera
  sees the board becomes a sample when its first camera's view is far
  enough from every sample kept
  (`VisionCore.Calibration.Coverage.good_sample?/2`). Without a
  subscriber nothing is detected, and the samples stay. A camera whose
  detection answers an error, such as a frame that does not decode, is
  logged once, then again only after one of its detections has worked.

  `solve/0`, once the samples are `good_enough`, runs
  `VisionCore.Calibration.Solver` on them. `apply/0` commits the solved
  calibration (`VisionCore.Stereo.Calibration.commit/2` for a pair,
  `VisionCore.Camera.Calibration.commit/3` for a camera) and answers at
  once: the outcome comes as the next state. A commit ends the session,
  a refusal leaves it solved, with the error. `cancel/0` ends the session
  at any point but during an apply, killing a running solve.

  The phases: `:idle`, `:capturing`, `:solving`, `:solved`, `:applying`,
  then `:idle` again. A failed solve goes back to `:capturing`, with the
  error.

  Detection, solve and commit run in tasks under the
  `VisionCore.Calibration.Tasks` `Task.Supervisor`, one at a time, not
  linked to the session: a commit, which may restart the stereo unit,
  outlives whoever asked for it.

  The session takes its target's frames from `start/2` until it is idle
  again, and none outside a session. `VisionCore.Outputs` holds the
  subscriptions across the cameras' restarts, such as the one a first
  calibration's commit causes.

  Each subscriber receives `{:calibration_session, state}` on every
  change; a change of the last detection alone, at most `:detect_hz`
  times a second.

  ## Options

    * `:config` (required) — the active `VisionCore.Config`.
    * `:detect_hz` (15) — the most detections a second.
    * `:pair_tolerance_ms` (the `:stereo` component's, else 33) — the
      largest capture time gap of a pair.
    * `:detect` (`VisionCore.Calibration.Chessboard.detect/2`),
      `:solve` (`VisionCore.Calibration.Solver.solve/3`),
      `:commit` (`VisionCore.Stereo.Calibration.commit/2`),
      `:solve_camera` (`VisionCore.Calibration.Solver.solve_camera/3`),
      `:commit_camera` (`VisionCore.Camera.Calibration.commit/3`) — what
      the tasks run.
  """
  use GenServer
  require Logger

  alias VisionCore.Calibration
  alias VisionCore.Calibration.{Board, Chessboard, Coverage, Solver}
  alias VisionCore.Camera.Frame
  alias VisionCore.Outputs

  @tasks VisionCore.Calibration.Tasks
  @default_detect_hz 15
  @default_pair_tolerance_ms 33
  @frames_kept 4

  @type phase :: :idle | :capturing | :solving | :solved | :applying
  @type fractions :: [{float(), float()}]
  @typedoc """
  The session as its subscribers see it. `target` is the id and kind of
  the target being calibrated, `detection` the board's corners in each
  camera's last frame, by the frames' label, as fractions of the frame,
  and `result` the solve's, a pair's or a camera's.
  """
  @type state :: %{
          phase: phase(),
          target: %{id: String.t(), kind: :stereo | :camera} | nil,
          board: Board.t() | nil,
          samples: non_neg_integer(),
          progress: Coverage.params(),
          good_enough: boolean(),
          detection: %{views: %{String.t() => fractions() | nil}, sample: boolean()} | nil,
          result: Solver.result() | Solver.camera_result() | nil,
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

  @doc """
  Starts capturing views of `board` with the cameras of the target `id`.
  Refused while a session runs, or the cameras do not;
  `{:error, :not_found}` for an id that is none of the unit's targets.
  """
  @spec start(String.t(), Board.t()) :: :ok | {:error, :not_found | String.t()}
  def start(id, %Board{} = board) when is_binary(id),
    do: GenServer.call(__MODULE__, {:start, id, board})

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
         targets: Calibration.targets(config),
         interval_ms: max(1, round(1_000 / detect_hz)),
         pair_tolerance_ns: tolerance_ms * 1_000_000,
         detect: Keyword.get(opts, :detect, &Chessboard.detect/2),
         solve: Keyword.get(opts, :solve, &Solver.solve/3),
         commit: Keyword.get(opts, :commit, &VisionCore.Stereo.Calibration.commit/2),
         solve_camera: Keyword.get(opts, :solve_camera, &Solver.solve_camera/3),
         commit_camera:
           Keyword.get(opts, :commit_camera, &VisionCore.Camera.Calibration.commit/3),
         subscribers: %{},
         task: nil,
         tick: nil,
         frames: %{},
         last_broadcast_ms: nil,
         pending_broadcast: nil,
         failing: MapSet.new()
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
      target: nil,
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

  def handle_call({:start, id, board}, _from, %{phase: :idle} = state) do
    case Enum.find(state.targets, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      target ->
        if cameras_running?(target.servers) do
          for key <- target.frame_keys, do: :ok = Outputs.subscribe(key)
          state = %{state | phase: :capturing, target: target, board: board}
          {:reply, :ok, state |> broadcast() |> settle()}
        else
          {:reply, {:error, not_running(target)}, state}
        end
    end
  end

  def handle_call({:start, _id, _board}, _from, state),
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
      solve = solver(state)
      state = stop_task(state)
      task = Task.Supervisor.async_nolink(@tasks, solve)
      state = %{state | phase: :solving, task: {:solve, task}, detection: nil, error: nil}
      {:reply, :ok, state |> broadcast() |> settle()}
    else
      {:reply, {:error, "the samples do not cover enough views of the board yet"}, state}
    end
  end

  def handle_call(:solve, _from, state),
    do: {:reply, {:error, "the session is not capturing"}, state}

  def handle_call(:apply, _from, %{phase: :solved, result: result} = state) do
    task = Task.Supervisor.async_nolink(@tasks, committer(state, result))
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
    for key <- state.target.frame_keys, do: :ok = Outputs.unsubscribe(key)
    Map.merge(state, idle())
  end

  defp cameras_running?([]), do: false
  defp cameras_running?(servers), do: Enum.all?(servers, &(GenServer.whereis(&1) != nil))

  defp not_running(%{kind: :stereo}), do: "the stereo cameras are not running"
  defp not_running(%{kind: :camera}), do: "the camera is not running"

  defp solver(%{target: %{kind: :stereo}, solve: solve, board: board, size: size} = state) do
    samples =
      for %{views: views} <- state.samples, do: %{left: views["left"], right: views["right"]}

    fn -> solve.(board, size, samples) end
  end

  defp solver(%{target: %{kind: :camera, labels: [label]}, board: board, size: size} = state) do
    %{solve_camera: solve} = state
    views = for %{views: views} <- state.samples, do: views[label]
    fn -> solve.(board, size, views) end
  end

  defp committer(%{target: %{kind: :stereo}, commit: commit, config: config}, result),
    do: fn -> commit.(config, %{left: result.left, right: result.right}) end

  defp committer(%{target: %{kind: :camera, name: name}, config: config} = state, result) do
    %{commit_camera: commit} = state
    fn -> commit.(config, name, result.camera) end
  end

  defp detecting?(state), do: state.phase == :capturing and state.subscribers != %{}

  # The newest frames of each of the target's cameras, by label; a frame of another camera is dropped.
  defp keep_frame(%{target: %{labels: labels}} = state, %Frame{label: label} = frame) do
    if label in labels do
      kept = Enum.take([frame | Map.get(state.frames, label, [])], @frames_kept)
      %{state | frames: Map.put(state.frames, label, kept)}
    else
      state
    end
  end

  # One tick pending while detecting; the frames go once nothing is detected.
  defp settle(state) do
    cond do
      not detecting?(state) -> %{state | frames: %{}}
      state.tick == nil -> %{state | tick: Process.send_after(self(), :tick, state.interval_ms)}
      true -> state
    end
  end

  defp detect(%{task: nil, target: %{labels: [first | others]}} = state) do
    with [%Frame{} = frame | _older] <- Map.get(state.frames, first),
         partners when is_list(partners) <- partners(state, frame, others) do
      %{detect: detect, board: board} = state
      frames = [frame | partners]
      task = Task.Supervisor.async_nolink(@tasks, fn -> detect_frames(detect, board, frames) end)
      %{state | task: {:detect, task}, frames: Map.delete(state.frames, first)}
    else
      _no_frames -> state
    end
  end

  defp detect(state), do: state

  # The frame of each other camera closest in capture time to `frame`, `nil` when one has none close enough.
  defp partners(state, frame, labels) do
    Enum.reduce_while(labels, [], fn label, partners ->
      case closest(frame, Map.get(state.frames, label, []), state.pair_tolerance_ns) do
        nil -> {:halt, nil}
        partner -> {:cont, partners ++ [partner]}
      end
    end)
  end

  defp closest(frame, others, tolerance_ns) do
    others
    |> Enum.filter(&(abs(&1.capture_ns - frame.capture_ns) <= tolerance_ns))
    |> Enum.min_by(&abs(&1.capture_ns - frame.capture_ns), fn -> nil end)
  end

  defp detect_frames(detect, board, [first | _others] = frames) do
    found = for frame <- frames, do: {frame.label, detect.(frame, board)}
    views = Map.new(found, fn {label, answer} -> {label, corners(answer)} end)
    sizes = Map.new(frames, &{&1.label, {&1.width, &1.height}})

    parameters =
      if Enum.all?(Map.values(views)),
        do: Coverage.parameters(views[first.label], board, sizes[first.label])

    %{
      first: first.label,
      views: views,
      sizes: sizes,
      parameters: parameters,
      errors: for({label, answer} <- found, do: {label, detect_error(answer)})
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
      views:
        Map.new(found.views, fn {label, view} -> {label, fractions(view, found.sizes[label])} end),
      sample: sample?
    }

    if sample? do
      sample = %{views: found.views, parameters: found.parameters}

      broadcast(%{
        state
        | samples: state.samples ++ [sample],
          size: state.size || found.sizes[found.first],
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
    failing =
      Enum.reduce(errors, state.failing, fn
        {label, nil}, failing ->
          MapSet.delete(failing, label)

        {label, reason}, failing ->
          if not MapSet.member?(failing, label),
            do: Logger.warning("#{__MODULE__} #{label} detection failed: #{inspect(reason)}")

          MapSet.put(failing, label)
      end)

    %{state | failing: failing}
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
      target: state.target && Map.take(state.target, [:id, :kind]),
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

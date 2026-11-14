defmodule VisionCore.CameraPipeline do
  @moduledoc """
  The loop of a pipeline that runs a model on the frames of a camera of
  its own and matches each result with the stereo pair captured closest
  to its frame: one inference in flight, the newest frame held
  meanwhile, and the results waiting for their pairs in capture order.
  `VisionCore.Detection.CameraPipeline` and
  `VisionCore.Segmentation.Pipeline` each run one, and say, as its
  callbacks, what goes to the backend and what a result and its pair
  become.

  ## One inference in flight

  The pipeline counts the camera's frames that come while fewer than 32
  results wait for their pair, a frame that comes while an inference is
  in flight included: the `n`th, `2n`th, `3n`th… of them, `n` being
  `c:every_n/1`, are to be inferred on, with `n` = 2 the second, fourth,
  sixth… Of those, a frame the pipeline does not accept (`c:accept/2`)
  is skipped.

  One inference is in flight at a time, submitted under a sequence
  number its reply is matched on; every submission takes a new number, a
  refused one included, so a late reply never matches a later frame. A
  frame to infer on that comes meanwhile is held, in place of the one
  held before, and submitted once that reply is handled, `nil` included,
  before the reply's result is matched with a pair. It is not submitted
  as soon as the backend is free: the reply may still be waiting to be
  read, and would be lost. The frame held is dropped when 32 results
  wait once the reply is handled, or when the backend refuses it. A
  frame the backend could not infer on, answered with `nil`, publishes
  nothing.

  ## The stereo pair

  A result that needs depth (`c:result/3`) waits for the stereo pair
  captured closest to its frame (`VisionCore.CameraDepth`) in
  a queue (`VisionCore.CameraDepth.Queue`) while the next frames go
  to the backend, and leaves it in capture order: at most
  `:pair_wait_ms`, and not at all while the stereo pairs have stalled,
  two pair periods without one. A result that needs none, and any
  result of a camera without a calibration or a pose, or whose
  calibration cannot be projected at the frame's size, waits for no
  pair. Each result leaving the queue is finished with its pair, `nil`
  without one (`c:finish/5`), and published through `VisionCore.Outputs`
  under `c:output_key/1`.

  The camera's calibration and pose are read at start, and again at
  each change of the camera's calibration
  (`VisionCore.Camera.Calibration.changed_key/1`), so a calibration
  committed while the pipeline runs is taken from the next frame on.

  ## The steps' times

  The pipeline times what it does for each frame inferred on, under the
  names `c:stage/1` gives its steps: preparing the frame and handing it
  to the backend (`:prepare`), the inference, from the frame handed over
  to its reply, as `:inference`, making the result of the reply
  (`:result`) and finishing it with its pair (`:finish`). The wait for
  the pair is in none of them, and a frame the backend could not infer
  on has no inference time. `stage_times/1` hands the times over and
  starts them again.

  ## Options

  The pipeline's own, which `c:init/1` reads, and:

    * `:config` (the active `VisionCore.Config`) — the configuration the
      camera is read from.
    * `:clock` (`System.monotonic_time/1` in nanoseconds) — the time the
      steps and the waits for a pair are measured with, a function of no
      argument.
  """
  use GenServer

  alias VisionCore.Camera.Frame
  alias VisionCore.{CameraDepth, Outputs, StageTimes}
  alias VisionCore.Stereo.Pair

  @typedoc """
  What a pipeline keeps of its options, as `c:init/1` returns it, with
  at least its `:name`, its `:source`, `{:camera, camera, output}`,
  `output` being `nil` for the camera's default, and its
  `:pair_wait_ms`.
  """
  @type settings :: %{
          required(:name) => atom(),
          required(:source) => {:camera, atom(), atom() | nil},
          required(:pair_wait_ms) => non_neg_integer(),
          optional(atom()) => term()
        }

  @doc "The pipeline's settings, from its options. Raises on one it cannot run with."
  @callback init(opts :: keyword()) :: settings()

  @doc "The `n` of the frames to infer on: every `n`th."
  @callback every_n(settings()) :: pos_integer()

  @doc """
  The owner the warnings about the camera's depth name, and what they
  say is lost (`VisionCore.CameraDepth.new/5`).
  """
  @callback depth_wording(settings()) :: {owner :: String.t(), CameraDepth.wording()}

  @doc """
  The steps the pipeline declares in `VisionCore.Parameters`, once it
  runs: their live parameters read `c:setting_values/1` and set
  `c:with_setting/3` through its process (`:live_settings` and
  `{:put_setting, key, value}` calls).
  """
  @callback groups(settings()) :: [VisionCore.Parameters.group_declaration()]

  @doc "The settings that change while the pipeline runs, among `settings`, by their names."
  @callback setting_values(settings()) :: %{String.t() => term()}

  @doc "`settings` with the setting `key` at `value`, or why it is refused."
  @callback with_setting(settings(), key :: atom(), value :: term()) ::
              {:ok, settings()} | {:error, String.t()}

  @doc "The `VisionCore.Outputs` key the pipeline publishes under."
  @callback output_key(settings()) :: Outputs.key()

  @doc "Whether `frame`, one to infer on, can be: `:skip` for one that cannot."
  @callback accept(Frame.t(), settings()) :: {:ok | :skip, settings()}

  @doc """
  What the backend is sent of `frame`, with what the pipeline keeps of
  it for its result beside the frame without its pixels; `:skip` for a
  frame nothing can be sent of.
  """
  @callback prepare(Frame.t(), settings()) ::
              {:submit, request :: term(), kept :: term(), settings()} | {:skip, settings()}

  @doc "Hands `request` to the backend as the inference `sequence`."
  @callback submit(request :: term(), sequence :: non_neg_integer(), settings()) ::
              :ok | {:error, term()}

  @doc "The tag of the message the backend answers in, `{tag, sequence, reply}`."
  @callback reply_tag() :: atom()

  @doc """
  What the pipeline makes of the backend's `reply` to a frame, with what
  it kept of that frame, and whether it needs the frame's stereo pair.
  """
  @callback result(reply :: term(), kept :: term(), settings()) ::
              {result :: term(), needs_depth? :: boolean()}

  @doc """
  The message published for `frame`'s `result`, finished with `pair`,
  the stereo pair matched with the frame, `nil` without one, and the
  camera's depth, which keeps the lenses it projects through.
  """
  @callback finish(Frame.t(), result :: term(), Pair.t() | nil, CameraDepth.t(), settings()) ::
              {message :: term(), CameraDepth.t()}

  @doc """
  The step of the pipeline, as its parameter group names it
  (`<name>.<step>`), that what the pipeline does in `phase` is timed as;
  `nil` for a phase that is none of its steps.
  """
  @callback stage(phase :: :prepare | :result | :finish) :: atom() | nil

  @phases [:prepare, :result, :finish]

  @doc """
  Each step's time over the frames inferred on since the last call,
  which this starts again.
  """
  @spec stage_times(GenServer.server()) :: StageTimes.t()
  def stage_times(server), do: GenServer.call(server, :stage_times)

  @doc "Starts the pipeline `module`; `start_options` are `GenServer.start_link/3`'s."
  @spec start_link(module(), keyword(), keyword()) :: GenServer.on_start()
  def start_link(module, opts, start_options),
    do: GenServer.start_link(__MODULE__, {module, opts}, start_options)

  @impl GenServer
  def init({module, opts}) do
    settings = module.init(opts)

    config =
      Keyword.get_lazy(opts, :config, &VisionCore.Application.active_config/0) ||
        %VisionCore.Config{}

    state = %{
      module: module,
      settings: settings,
      reply_tag: module.reply_tag(),
      output_key: module.output_key(settings),
      config: config,
      camera: camera_depth(module, settings, config),
      # The sequence of the last submission, accepted or not.
      sequence: 0,
      frame_count: 0,
      # The in-flight inference: its sequence, its frame without its pixels, and what was kept of it.
      pending: nil,
      # The newest frame to infer on that came while one was in flight, with its pixels.
      held: nil,
      # Frames' results waiting for the pair captured closest to each.
      waiting: CameraDepth.Queue.new(settings.pair_wait_ms),
      clock: Keyword.get(opts, :clock, &monotonic_ns/0),
      times:
        StageTimes.new([:inference | Enum.reject(Enum.map(@phases, &module.stage/1), &is_nil/1)])
    }

    :ok = Outputs.subscribe({:stereo_pair, VisionCore.Stereo.Pipeline})
    :ok = Outputs.subscribe(state.camera.key)
    :ok = Outputs.subscribe(VisionCore.Camera.Calibration.changed_key(state.camera.name))
    {:ok, state, {:continue, :declare}}
  end

  # After `init/1`: the registry reads the settings it is declared from the running pipeline.
  @impl GenServer
  def handle_continue(:declare, state) do
    if Process.whereis(VisionCore.Parameters),
      do: :ok = VisionCore.Parameters.declare(state.module.groups(state.settings))

    {:noreply, state}
  end

  defp monotonic_ns, do: System.monotonic_time(:nanosecond)

  defp camera_depth(module, %{source: {:camera, camera, output}} = settings, config) do
    {owner, wording} = module.depth_wording(settings)

    CameraDepth.new(camera, config, owner, wording,
      pair_wait_ms: settings.pair_wait_ms,
      output: output
    )
  end

  @impl GenServer
  def handle_call(:stage_times, _from, state),
    do: {:reply, state.times, %{state | times: StageTimes.reset(state.times)}}

  def handle_call(:live_settings, _from, state),
    do: {:reply, state.module.setting_values(state.settings), state}

  def handle_call({:put_setting, key, value}, _from, state) do
    case state.module.with_setting(state.settings, key, value) do
      {:ok, settings} -> {:reply, :ok, with_pair_wait(%{state | settings: settings})}
      {:error, _reason} = refusal -> {:reply, refusal, state}
    end
  end

  # The results put from now on wait, and the pairs are kept, as long as the setting says.
  defp with_pair_wait(%{settings: %{pair_wait_ms: pair_wait_ms}} = state) do
    %{
      state
      | waiting: CameraDepth.Queue.put_pair_wait_ms(state.waiting, pair_wait_ms),
        camera: CameraDepth.put_pair_wait_ms(state.camera, pair_wait_ms)
    }
  end

  @impl GenServer
  def handle_cast({:stereo_pair, %Pair{} = pair}, state) do
    now_ns = state.clock.()
    state = %{state | camera: CameraDepth.add_pair(state.camera, pair, now_ns)}
    {:noreply, publish_settled(state, now_ns)}
  end

  def handle_cast({:camera_frame, %Frame{} = frame}, state) do
    case CameraDepth.Queue.admit(state.waiting, state.camera) do
      {:ok, waiting} -> {:noreply, take_frame(frame, %{state | waiting: waiting})}
      {:full, waiting} -> {:noreply, %{state | waiting: waiting}}
    end
  end

  # The results still waiting are finished with the calibration committed.
  def handle_cast({:camera_calibration_changed, name}, %{camera: %{name: name}} = state),
    do: {:noreply, %{state | camera: CameraDepth.reload(state.camera, state.config)}}

  def handle_cast(_message, state), do: {:noreply, state}

  defp take_frame(frame, state) do
    frame_count = state.frame_count + 1
    state = %{state | frame_count: frame_count}

    if rem(frame_count, state.module.every_n(state.settings)) == 0,
      do: take_accepted(frame, state),
      else: state
  end

  defp take_accepted(frame, state) do
    case state.module.accept(frame, state.settings) do
      {:skip, settings} -> %{state | settings: settings}
      {:ok, settings} when is_nil(state.pending) -> submit(frame, %{state | settings: settings})
      {:ok, settings} -> %{state | settings: settings, held: frame}
    end
  end

  # Submits the frame held while the queue has room for its result.
  defp submit_held(%{held: nil} = state), do: state

  defp submit_held(%{held: frame} = state) do
    case CameraDepth.Queue.admit(state.waiting, state.camera) do
      {:ok, waiting} -> submit(frame, %{state | held: nil, waiting: waiting})
      {:full, waiting} -> %{state | held: nil, waiting: waiting}
    end
  end

  defp submit(frame, state) do
    started_ns = state.clock.()

    case state.module.prepare(frame, state.settings) do
      {:submit, request, kept, settings} ->
        submit(request, frame, kept, started_ns, %{state | settings: settings})

      {:skip, settings} ->
        %{state | settings: settings}
    end
  end

  defp submit(request, frame, kept, started_ns, state) do
    sequence = state.sequence + 1
    state = %{state | sequence: sequence}

    case state.module.submit(request, sequence, state.settings) do
      :ok ->
        submitted_ns = state.clock.()
        frame = %{frame | jpeg: nil, grey: nil, rgb: nil}
        pending = %{sequence: sequence, frame: frame, kept: kept, submitted_ns: submitted_ns}
        time_phase(%{state | pending: pending}, :prepare, started_ns, submitted_ns)

      # Busy or unavailable: the backend logs the unavailable case once.
      {:error, _reason} ->
        state
    end
  end

  @impl GenServer
  def handle_info(
        {tag, sequence, reply},
        %{reply_tag: tag, pending: %{sequence: sequence} = pending} = state
      ) do
    state = %{state | pending: nil}

    if is_nil(reply),
      do: {:noreply, submit_held(state)},
      else: {:noreply, wait_for_pair(state, pending, reply)}
  end

  # A reply for a frame no longer waited on.
  def handle_info({tag, _stale, _reply}, %{reply_tag: tag} = state), do: {:noreply, state}

  def handle_info(:pair_wait, state), do: {:noreply, publish_settled(state, state.clock.())}

  def handle_info(_message, state), do: {:noreply, state}

  defp wait_for_pair(state, %{frame: frame, kept: kept, submitted_ns: submitted_ns}, reply) do
    replied_ns = state.clock.()
    {result, needs_depth?} = state.module.result(reply, kept, state.settings)
    now_ns = state.clock.()

    state =
      state
      |> time_stage(:inference, submitted_ns, replied_ns)
      |> time_phase(:result, replied_ns, now_ns)

    {lens, camera} = CameraDepth.lens(state.camera, {frame.width, frame.height})

    waiting =
      if needs_depth? and lens != nil and CameraDepth.projectable?(camera),
        do: CameraDepth.Queue.put(state.waiting, {frame, result}, frame.capture_ns, now_ns),
        else: CameraDepth.Queue.put_without_depth(state.waiting, {frame, result})

    # Submitted first, so the backend runs while the results are finished.
    %{state | camera: camera, waiting: waiting}
    |> submit_held()
    |> publish_settled(now_ns)
  end

  # Publishes the results whose pair is known, in capture order, and has the pipeline told when to look again.
  defp publish_settled(state, now_ns) do
    state = %{state | camera: CameraDepth.add_queued_pairs(state.camera, now_ns)}
    {settled, waiting} = CameraDepth.Queue.settle(state.waiting, state.camera, now_ns)
    state = %{state | waiting: CameraDepth.Queue.schedule(waiting, state.camera, now_ns)}

    Enum.reduce(settled, state, fn {{frame, result}, pair}, state ->
      started_ns = state.clock.()
      {message, camera} = state.module.finish(frame, result, pair, state.camera, state.settings)
      finished_ns = state.clock.()
      Outputs.publish(state.output_key, message)
      time_phase(%{state | camera: camera}, :finish, started_ns, finished_ns)
    end)
  end

  defp time_phase(state, phase, from_ns, to_ns),
    do: time_stage(state, state.module.stage(phase), from_ns, to_ns)

  defp time_stage(state, nil, _from_ns, _to_ns), do: state

  defp time_stage(state, stage, from_ns, to_ns),
    do: %{state | times: StageTimes.add(state.times, stage, (to_ns - from_ns) / 1_000_000)}
end

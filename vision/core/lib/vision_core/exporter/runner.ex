defmodule VisionCore.Exporter.Runner do
  @moduledoc """
  Runs a `VisionCore.Exporter`: starts it, subscribes to the outputs it
  names through `VisionCore.Outputs`, hands it the newest value of each,
  at most each output's `:max_hz` times a second and only while it is
  not busy with that output, answers its status by a deadline
  (`status/2`), and runs its actions (`action/4`). It passes the
  exporter's `c:VisionCore.Exporter.handle_info/2` the messages sent to
  the runner with `send/2` and the casts that are not outputs, such as
  those of the keys the exporter subscribed to from its
  `c:VisionCore.Exporter.init/1`. Calls other than `status/2`'s and
  `action/4`'s are answered `{:error, :unknown_call}`.

  When the runner takes a value from its mailbox, the newest value of
  the same output waiting there replaces it, so a slow exporter skips
  values instead of falling behind. A camera's video is the exception:
  each of its frames is handed over in order, from a key frame, with no
  `:max_hz`, those that come while the exporter is busy with it queued,
  up to a bound past which it skips to the next key frame
  (`VisionCore.Camera.VideoQueue`). A value that comes before its
  output's next slot opens, or while the exporter is busy with the
  output, is held, replaced by any newer one, and handed over once the
  slot is open and the exporter ready. The camera outputs tell their
  frames apart by `:label`, `"left"`, `"right"` or a camera's name, and
  by `:output`, the camera output a frame is of. Every other message is
  `{output, value}`, `output` being the output it is of: a detection
  pipeline's value is `{pair, detections}`, or `{frame, detections}`
  from a pipeline on a camera, a segmentation pipeline's
  `{frame, labels, clouds}`.

  The runner starts without waiting for its exporter: the exporter's
  `c:VisionCore.Exporter.init/1` runs right after, and when it fails or
  raises, the runner logs it, reports `{:warning, "Not started: reason"}`
  and calls it again later, the delay doubling up to a cap. It subscribes
  once `init/1` succeeds, and never calls `init/1` again. Every failure,
  of `init/1`, of a value's export, of `c:VisionCore.Exporter.status/1` or
  of `c:VisionCore.Exporter.handle_action/4`, is logged the first time,
  up to a bound for each of the four.

  A `c:VisionCore.Exporter.handle_output/3` or
  `c:VisionCore.Exporter.handle_info/2` that raises, throws, exits or
  answers none of its results does not stop the runner: the exporter
  keeps the state it had, the value counts as not exported, and the
  failure is logged once for the values in a row that fail. Until that
  output is handed a value that does not fail, or `handle_info/2` a
  message, the status is a warning naming the failure, whatever the
  exporter's own status says.

  Without the exporter's own `c:VisionCore.Exporter.status/1`, the status
  is `{:ok, "Running"}`, a warning while the last value handed over of
  any output was not exported, and the count of values not exported once
  some were. A `c:VisionCore.Exporter.status/1` that raises, or answers
  anything but `{:ok | :warning | :off, text}`, is a warning saying so, so
  that what `status/2` answers is always a status.

  `VisionCore.Exporter.Supervisor` starts it under the exporter's own
  supervisor.

  ## Options

    * `:exporter` — the module implementing `VisionCore.Exporter`
      (required).
    * `:options` (`[]`) — the exporter's options, given to its callbacks.
      A `:name` among them registers the runner under that name.
    * `:config` (the active `VisionCore.Config`) — the configuration its
      outputs resolve in (`VisionCore.Exporter.output_key/2`).

  It does not start when the exporter's outputs are invalid, with the
  error `VisionCore.Exporter.output_specs/2` says, nor when two of them
  resolve to one key in the configuration, such as `{:camera_frame,
  :hq}` and `{:camera_frame, :hq, :view}` on a camera whose default
  output is `:view`: `{:invalid_output, second}`, nor on a camera's
  output the camera does not send (`VisionCore.Camera.Unit.unsent_output?/3`):
  `{:unsent_output, output}`, nor on a video named as an image,
  `{:video_output, output}`, or an image named as a video,
  `{:image_output, output}`.
  """
  use GenServer
  require Logger
  require VisionCore.Outputs, as: Outputs

  alias VisionCore.Camera.{Frame, Unit, VideoQueue}
  alias VisionCore.Exporter

  @default_status_timeout_ms 200
  @first_retry_ms 500
  @max_retry_ms 30_000
  @max_logged_failures 32
  # An exporter further behind skips to the next key frame.
  @video_backlog_frames 30

  @doc "Starts the runner; see the module doc for `opts`."
  def start_link(opts) do
    case opts |> Keyword.get(:options, []) |> Keyword.get(:name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  The exporter's status, or the runner's own without
  `c:VisionCore.Exporter.status/1`; a warning when the runner, busy or
  stuck, does not answer within `timeout_ms`, and off when it is not
  running.
  """
  @spec status(GenServer.server(), timeout()) :: Exporter.status()
  def status(runner, timeout_ms \\ @default_status_timeout_ms) do
    GenServer.call(runner, :status, timeout_ms)
  catch
    :exit, {:timeout, _call} -> {:warning, "Not answering"}
    :exit, _reason -> {:off, "Not running"}
  end

  @doc """
  Runs the exporter's action named `name` with `params`
  (`c:VisionCore.Exporter.handle_action/4`), waiting up to `timeout` for
  its result: `{:error, :not_running}` before its
  `c:VisionCore.Exporter.init/1` succeeds, `{:error, :unknown_action}`
  for a name its `c:VisionCore.Exporter.actions/1` does not list, and
  `{:error, {:failed, reason}}` when `handle_action/4` raises or answers
  neither `{:reply, result, state}` nor `{:noreply, state}`, the
  exporter's state kept as it was. It exits, as `GenServer.call/3` does,
  when the runner stops or the deadline passes.
  """
  @spec action(GenServer.server(), String.t(), map(), timeout()) ::
          Exporter.action_result() | {:error, :not_running | :unknown_action}
  def action(runner, name, params, timeout),
    do: GenServer.call(runner, {:action, name, params}, timeout)

  @impl GenServer
  def init(opts) do
    exporter = Code.ensure_loaded!(Keyword.fetch!(opts, :exporter))
    options = Keyword.get(opts, :options, [])

    config = Keyword.get_lazy(opts, :config, &VisionCore.Application.active_config/0)

    with {:ok, specs} <- Exporter.output_specs(exporter, options),
         :ok <- check_sent(specs, config),
         :ok <- check_keys_apart(specs, config) do
      if function_exported?(exporter, :terminate, 2), do: Process.flag(:trap_exit, true)

      {:ok,
       %{
         exporter: exporter,
         options: options,
         config: config,
         outputs: slots(specs),
         slots: %{},
         started: false,
         exporter_state: nil,
         not_started: nil,
         retry_ms: @first_retry_ms,
         failures: 0,
         failing: %{},
         logged: %{
           init: MapSet.new(),
           status: MapSet.new(),
           output: MapSet.new(),
           action: MapSet.new()
         }
       }, {:continue, :start_exporter}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp check_sent(specs, config) do
    Enum.find_value(specs, :ok, fn
      {{:camera_frame, name, output} = camera_output, _max_hz} ->
        cond do
          Unit.unsent_output?(config, name, output) -> {:error, {:unsent_output, camera_output}}
          Unit.video_output?(config, name, output) -> {:error, {:video_output, camera_output}}
          true -> nil
        end

      {{:camera_video, name, output} = video, _max_hz} ->
        if Unit.output_key(config, name, output), do: {:error, {:image_output, video}}

      _other ->
        nil
    end)
  end

  # One key feeds one slot: a camera's default output named a second time by its name never would.
  defp check_keys_apart(specs, config) do
    specs
    |> Enum.reduce_while(%{}, fn {output, _max_hz}, keys ->
      case Exporter.output_key(output, config) do
        nil -> {:cont, keys}
        key when is_map_key(keys, key) -> {:halt, {:error, {:invalid_output, output}}}
        key -> {:cont, Map.put(keys, key, output)}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      _keys -> :ok
    end
  end

  @impl GenServer
  def handle_continue(:start_exporter, state), do: {:noreply, start_exporter(state)}

  @impl GenServer
  def handle_call(:status, _from, state) do
    {status, state} = status_of(state)
    {:reply, status, state}
  end

  def handle_call({:action, _name, _params}, _from, %{started: false} = state),
    do: {:reply, {:error, :not_running}, state}

  def handle_call({:action, name, params}, from, %{exporter: exporter} = state) do
    case Enum.find(Exporter.actions(exporter, state.options), &(Atom.to_string(&1.name) == name)) do
      nil -> {:reply, {:error, :unknown_action}, state}
      %{name: action} -> run_action(state, action, params, from)
    end
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :unknown_call}, state}

  @impl GenServer
  def handle_cast(message, state) do
    case route(message, state.slots) do
      nil -> handle_message(message, state)
      {:camera_video, _name, _output} = video -> {:noreply, queue(state, video, payload(message))}
      output -> {:noreply, offer(state, output, newest(output, payload(message)))}
    end
  end

  @impl GenServer
  def handle_info({__MODULE__, :start_exporter}, %{started: false} = state),
    do: {:noreply, start_exporter(state)}

  def handle_info({__MODULE__, :start_exporter}, state), do: {:noreply, state}

  def handle_info({__MODULE__, :slot_open, output, timer}, state) do
    case state.slots do
      %{^output => %{timer: ^timer}} ->
        {:noreply, state |> put_in([:slots, output, :timer], nil) |> release(output)}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}
  def handle_info(message, state), do: handle_message(message, state)

  defp handle_message(_message, %{started: false} = state), do: {:noreply, state}

  defp handle_message(message, %{exporter: exporter} = state) do
    if function_exported?(exporter, :handle_info, 2),
      do: {:noreply, hand_message(state, message)},
      else: {:noreply, state}
  end

  defp hand_message(%{exporter: exporter} = state, message) do
    case exporter.handle_info(message, state.exporter_state) do
      {:ok, exporter_state} ->
        succeeded(%{state | exporter_state: exporter_state}, :handle_info)

      {:ready, outputs, exporter_state} ->
        %{state | exporter_state: exporter_state}
        |> succeeded(:handle_info)
        |> ready(List.wrap(outputs))

      malformed ->
        failed(state, :handle_info, "handle_info/2 returned " <> inspect(malformed))
    end
  catch
    kind, reason -> failed(state, :handle_info, failure_text(kind, reason))
  end

  @impl GenServer
  def terminate(reason, %{started: true, exporter: exporter} = state) do
    if function_exported?(exporter, :terminate, 2),
      do: exporter.terminate(reason, state.exporter_state)
  end

  def terminate(_reason, _state), do: :ok

  defp start_exporter(%{exporter: exporter} = state) do
    case init_exporter(exporter, state.options) do
      {:ok, exporter_state} ->
        slots = subscribe(state.outputs, state.config)

        %{
          state
          | started: true,
            exporter_state: exporter_state,
            not_started: nil,
            slots: slots
        }

      {:error, reason} ->
        Process.send_after(self(), {__MODULE__, :start_exporter}, state.retry_ms)

        %{state | not_started: reason, retry_ms: min(state.retry_ms * 2, @max_retry_ms)}
        |> log_once(:init, reason, :warning, "#{inspect(exporter)} not started: #{reason}")
    end
  end

  defp init_exporter(exporter, options) do
    case exporter.init(options) do
      {:ok, exporter_state} -> {:ok, exporter_state}
      {:error, reason} -> {:error, inspect(reason)}
      other -> {:error, "init/1 returned " <> inspect(other)}
    end
  catch
    kind, reason -> {:error, failure_text(kind, reason)}
  end

  defp run_action(%{exporter: exporter} = state, action, params, from) do
    case exporter.handle_action(action, params, from, state.exporter_state) do
      {:reply, result, exporter_state} ->
        {:reply, result, %{state | exporter_state: exporter_state}}

      {:noreply, exporter_state} ->
        {:noreply, %{state | exporter_state: exporter_state}}

      malformed ->
        action_failed(state, action, "handle_action/4 returned " <> inspect(malformed))
    end
  catch
    kind, reason -> action_failed(state, action, failure_text(kind, reason))
  end

  defp action_failed(%{exporter: exporter} = state, action, text) do
    message = "#{inspect(exporter)} action #{action} failed: #{text}"
    {:reply, {:error, {:failed, text}}, log_once(state, :action, text, :error, message)}
  end

  defp status_of(%{started: false} = state),
    do: {{:warning, "Not started: " <> state.not_started}, state}

  defp status_of(%{failing: failing} = state) when map_size(failing) > 0 do
    {callback, text} = Enum.at(failing, 0)
    {{:warning, "Failing on #{inspect(callback)}: #{text}"}, state}
  end

  defp status_of(%{exporter: exporter} = state) do
    if function_exported?(exporter, :status, 1),
      do: exporter_status(state),
      else: {default_status(state), state}
  end

  defp exporter_status(%{exporter: exporter} = state) do
    case exporter.status(state.exporter_state) do
      {level, detail} = status when level in [:ok, :warning, :off] and is_binary(detail) ->
        {status, state}

      malformed ->
        answer = inspect(malformed)

        message =
          "#{inspect(exporter)} status/1 answered #{answer}, not {:ok | :warning | :off, text}"

        {{:warning, "Malformed status: " <> answer},
         log_once(state, :status, answer, :error, message)}
    end
  catch
    kind, reason ->
      text = failure_text(kind, reason)
      message = "#{inspect(exporter)} status failed: #{text}"
      {{:warning, "Status failed: " <> text}, log_once(state, :status, text, :error, message)}
  end

  defp default_status(%{failures: 0}), do: {:ok, "Running"}

  defp default_status(state) do
    case for(%{failed: {_count, _reason} = failed} <- Map.values(state.slots), do: failed) do
      [] ->
        {:ok, "Running; #{state.failures} values not exported"}

      failed ->
        {_count, reason} = Enum.max(failed)
        {:warning, "#{state.failures} values not exported, the last for #{inspect(reason)}"}
    end
  end

  # Per output: :max_hz interval, last hand-over, held value, timer, busy, failure, video queue.
  defp slots(specs) do
    Map.new(specs, fn {output, max_hz} ->
      {output,
       %{
         interval_ms: max_hz && round(1_000 / max_hz),
         handed_ms: nil,
         held: nil,
         timer: nil,
         busy: false,
         failed: nil,
         queue: video_queue(output)
       }}
    end)
  end

  defp video_queue({:camera_video, _name, _output}), do: VideoQueue.new(@video_backlog_frames)
  defp video_queue(_output), do: nil

  defp subscribe(outputs, config) do
    outputs
    |> Enum.flat_map(fn {output, slot} ->
      case Exporter.output_key(output, config) do
        nil ->
          []

        key ->
          :ok = Outputs.subscribe(key)
          [{output, Map.put(slot, :frame_output, frame_output(key))}]
      end
    end)
    |> Map.new()
  end

  # The output name a camera's frames published under `key` carry.
  defp frame_output({:camera_frame, _server, output}), do: output
  defp frame_output(_key), do: nil

  # The output a message is of, among those subscribed; `newest/2` matches the same shapes.
  defp route({:camera_frame, %{label: label, output: frame_output}}, slots) do
    Enum.find_value(slots, fn
      {output, %{frame_output: ^frame_output}} -> if camera_label(output) == label, do: output
      _slot -> nil
    end)
  end

  defp route(message, slots) do
    output = message_output(message)
    if is_map_key(slots, output), do: output
  end

  defp camera_label({:camera_frame, name}), do: Atom.to_string(name)
  defp camera_label({:camera_frame, name, _output}), do: Atom.to_string(name)
  defp camera_label({:camera_video, name, _output}), do: Atom.to_string(name)
  defp camera_label(_output), do: nil

  defp message_output({output, _value}), do: output
  defp message_output(_message), do: nil

  defp payload({_output, value}), do: value

  # The newest value of the output waiting in the mailbox replaces `value`.
  defp newest(output, %Frame{label: label, output: frame_output} = value)
       when is_tuple(output) and elem(output, 0) == :camera_frame do
    receive do
      Outputs.queued({:camera_frame, %{label: ^label, output: ^frame_output} = frame}) ->
        newest(output, frame)
    after
      0 -> value
    end
  end

  defp newest(output, value) do
    receive do
      Outputs.queued({^output, next}) -> newest(output, next)
    after
      0 -> value
    end
  end

  defp offer(state, output, value),
    do: state |> put_in([:slots, output, :held], value) |> release(output)

  defp queue(state, video, frame),
    do: state |> update_in([:slots, video, :queue], &VideoQueue.push(&1, frame)) |> release(video)

  defp ready(state, outputs) do
    outputs
    |> Enum.filter(&is_map_key(state.slots, &1))
    |> Enum.reduce(state, fn output, state ->
      state |> put_in([:slots, output, :busy], false) |> release(output)
    end)
  end

  # A video's queued frames, in order, while the exporter is not busy with it.
  defp release(state, {:camera_video, _name, _output} = video) do
    slot = state.slots[video]

    with false <- slot.busy,
         {:ok, frame, queue} <- VideoQueue.pop(slot.queue) do
      state
      |> put_in([:slots, video, :queue], queue)
      |> hand_over(video, frame, now_ms())
      |> release(video)
    else
      _busy_or_empty -> state
    end
  end

  # Hands the held value over when the slot is open and the exporter not busy, or awaits the slot.
  defp release(state, output) do
    slot = state.slots[output]
    now_ms = now_ms()

    cond do
      is_nil(slot.held) or slot.busy ->
        state

      open?(slot, now_ms) ->
        hand_over(state, output, newest(output, slot.held), now_ms)

      slot.timer != nil ->
        state

      true ->
        timer = make_ref()
        opens_in_ms = slot.handed_ms + slot.interval_ms - now_ms
        Process.send_after(self(), {__MODULE__, :slot_open, output, timer}, opens_in_ms)
        put_in(state, [:slots, output, :timer], timer)
    end
  end

  defp open?(%{interval_ms: nil}, _now_ms), do: true
  defp open?(%{handed_ms: nil}, _now_ms), do: true
  defp open?(slot, now_ms), do: now_ms - slot.handed_ms >= slot.interval_ms

  # A slot timer still on its way when the value is handed over no longer matches the slot.
  defp hand_over(%{exporter: exporter} = state, output, value, now_ms) do
    state
    |> update_in([:slots, output], &%{&1 | held: nil, handed_ms: now_ms, timer: nil})
    |> export(exporter, output, value)
  end

  defp export(state, exporter, output, value) do
    case exporter.handle_output(output, value, state.exporter_state) do
      {:ok, exporter_state} ->
        state = put_in(state, [:slots, output, :failed], nil)
        succeeded(%{state | exporter_state: exporter_state}, output)

      {:busy, exporter_state} ->
        state = update_in(state, [:slots, output], &%{&1 | busy: true, failed: nil})
        succeeded(%{state | exporter_state: exporter_state}, output)

      {:error, reason, exporter_state} ->
        failures = state.failures + 1
        message = "#{inspect(exporter)} did not export #{inspect(output)}: #{inspect(reason)}"

        state
        |> put_in([:slots, output, :failed], {failures, reason})
        |> Map.merge(%{exporter_state: exporter_state, failures: failures})
        |> succeeded(output)
        |> log_once(:output, reason, :warning, message)

      malformed ->
        failed(state, output, "handle_output/3 returned " <> inspect(malformed))
    end
  catch
    kind, reason -> failed(state, output, failure_text(kind, reason))
  end

  # A callback that raised, threw, exited or answered nothing known: the exporter keeps its state.
  defp failed(%{exporter: exporter} = state, callback, text) do
    unless is_map_key(state.failing, callback),
      do: Logger.error("#{inspect(exporter)} failed on #{inspect(callback)}: #{text}")

    %{state | failing: Map.put(state.failing, callback, text), failures: state.failures + 1}
  end

  defp succeeded(state, callback), do: %{state | failing: Map.delete(state.failing, callback)}

  # Each distinct failure of a `kind` once, up to a bound for that kind, however often it recurs.
  defp log_once(state, kind, failure, level, message) do
    logged = Map.fetch!(state.logged, kind)

    if MapSet.member?(logged, failure) or MapSet.size(logged) >= @max_logged_failures do
      state
    else
      Logger.log(level, message)
      put_in(state, [:logged, kind], MapSet.put(logged, failure))
    end
  end

  defp failure_text(:error, reason), do: Exception.message(Exception.normalize(:error, reason))
  defp failure_text(_kind, reason), do: inspect(reason)

  defp now_ms, do: System.monotonic_time(:millisecond)
end

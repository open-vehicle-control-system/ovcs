defmodule VisionCore.Exporter.Runner do
  @moduledoc """
  Runs a `VisionCore.Exporter`: starts it, subscribes to the outputs it
  names through `VisionCore.Outputs`, hands it the newest value of each,
  at most each output's `:max_hz` times a second and only while it is
  not busy with that output, passes it the messages sent to the runner
  with `send/2`, and answers its status by a deadline (`status/2`).
  Casts that are not outputs are dropped.

  When the runner takes a value from its mailbox, the newest value of
  the same output waiting there replaces it, so a slow exporter skips
  values instead of falling behind. A value that comes before its
  output's next slot opens, or while the exporter is busy with the
  output, is held, replaced by any newer one, and handed over once the
  slot is open and the exporter ready. The camera outputs tell their
  frames apart by `:label`, `"left"` or `"right"`.

  The runner starts without waiting for its exporter: the exporter's
  `c:VisionCore.Exporter.init/1` runs right after, and when it fails or
  raises, the runner logs it, reports `{:warning, "Not started: reason"}`
  and calls it again later, the delay doubling up to a cap. It subscribes
  once `init/1` succeeds. Every failure, of `init/1`, of a value's export
  or of `c:VisionCore.Exporter.status/1`, is logged the first time.

  Without the exporter's own `c:VisionCore.Exporter.status/1`, the status
  is `{:ok, "Running"}`, a warning while the last value handed over was
  not exported, and the count of values not exported once some were.

  `VisionCore.Exporter.Supervisor` starts it under the exporter's own
  supervisor.

  ## Options

    * `:exporter` — the module implementing `VisionCore.Exporter`
      (required).
    * `:options` (`[]`) — the exporter's options, given to its callbacks.
      A `:name` among them registers the runner under that name.
    * `:config` (the active `VisionCore.Config`) — the configuration its
      outputs resolve in (`VisionCore.Exporter.output_key/2`).

  It does not start, with `{:invalid_output, entry}`, when an entry of
  the exporter's outputs names no output, names one a second time, or
  has options other than a positive `:max_hz`.
  """
  use GenServer
  require Logger

  alias VisionCore.{Exporter, Outputs}

  @default_status_timeout_ms 200
  @first_retry_ms 500
  @max_retry_ms 30_000
  @max_logged_failures 32

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

  @impl GenServer
  def init(opts) do
    exporter = Code.ensure_loaded!(Keyword.fetch!(opts, :exporter))
    options = Keyword.get(opts, :options, [])

    case slots(exporter.outputs(options)) do
      {:ok, outputs} ->
        if function_exported?(exporter, :terminate, 2), do: Process.flag(:trap_exit, true)

        {:ok,
         %{
           exporter: exporter,
           options: options,
           config: Keyword.get_lazy(opts, :config, &VisionCore.Application.active_config/0),
           outputs: outputs,
           slots: %{},
           routes: %{},
           started: false,
           exporter_state: nil,
           not_started: nil,
           retry_ms: @first_retry_ms,
           failures: 0,
           last_failed: false,
           last_failure: nil,
           logged: MapSet.new()
         }, {:continue, :start_exporter}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_continue(:start_exporter, state), do: {:noreply, start_exporter(state)}

  @impl GenServer
  def handle_call(:status, _from, state) do
    {status, state} = status_of(state)
    {:reply, status, state}
  end

  @impl GenServer
  def handle_cast(message, state) do
    case route(message, state.routes) do
      nil -> {:noreply, state}
      output -> {:noreply, offer(state, output, newest(output, payload(message)))}
    end
  end

  @impl GenServer
  def handle_info({__MODULE__, :start_exporter}, state), do: {:noreply, start_exporter(state)}

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
  def handle_info(_message, %{started: false} = state), do: {:noreply, state}

  def handle_info(message, %{exporter: exporter} = state) do
    if function_exported?(exporter, :handle_info, 2) do
      case exporter.handle_info(message, state.exporter_state) do
        {:ok, exporter_state} ->
          {:noreply, %{state | exporter_state: exporter_state}}

        {:ready, outputs, exporter_state} ->
          {:noreply, ready(%{state | exporter_state: exporter_state}, List.wrap(outputs))}
      end
    else
      {:noreply, state}
    end
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
            slots: slots,
            routes: Map.new(slots, fn {output, _slot} -> {message_tag(output), output} end)
        }

      {:error, reason} ->
        Process.send_after(self(), {__MODULE__, :start_exporter}, state.retry_ms)

        %{state | not_started: reason, retry_ms: min(state.retry_ms * 2, @max_retry_ms)}
        |> log_once({:init, reason}, :warning, "#{inspect(exporter)} not started: #{reason}")
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

  defp status_of(%{started: false} = state),
    do: {{:warning, "Not started: " <> state.not_started}, state}

  defp status_of(%{exporter: exporter} = state) do
    if function_exported?(exporter, :status, 1),
      do: exporter_status(state),
      else: {default_status(state), state}
  end

  defp exporter_status(%{exporter: exporter} = state) do
    {exporter.status(state.exporter_state), state}
  catch
    kind, reason ->
      text = failure_text(kind, reason)
      message = "#{inspect(exporter)} status failed: #{text}"
      {{:warning, "Status failed: " <> text}, log_once(state, {:status, text}, :error, message)}
  end

  defp default_status(%{failures: 0}), do: {:ok, "Running"}

  defp default_status(%{last_failed: true} = state) do
    last = inspect(state.last_failure)
    {:warning, "#{state.failures} values not exported, the last for #{last}"}
  end

  defp default_status(state), do: {:ok, "Running; #{state.failures} values not exported"}

  # Per output: its :max_hz interval, last hand-over, held value, slot timer and busy flag.
  defp slots(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, slots} ->
      case entry_slot(entry) do
        {output, slot} when not is_map_key(slots, output) ->
          {:cont, {:ok, Map.put(slots, output, slot)}}

        _invalid ->
          {:halt, {:error, {:invalid_output, entry}}}
      end
    end)
  end

  defp entry_slot({output, options}) when is_list(options) do
    with true <- Exporter.output?(output),
         {:ok, interval_ms} <- interval_ms(options) do
      {output, %{interval_ms: interval_ms, handed_ms: nil, held: nil, timer: nil, busy: false}}
    else
      _invalid -> nil
    end
  end

  defp entry_slot(output), do: entry_slot({output, []})

  defp interval_ms([]), do: {:ok, nil}

  defp interval_ms(max_hz: max_hz) when is_number(max_hz) and max_hz > 0,
    do: {:ok, round(1_000 / max_hz)}

  defp interval_ms(_options), do: :error

  defp subscribe(outputs, config) do
    outputs
    |> Enum.flat_map(fn {output, slot} ->
      case Exporter.output_key(output, config) do
        nil ->
          []

        key ->
          :ok = Outputs.subscribe(key)
          [{output, slot}]
      end
    end)
    |> Map.new()
  end

  # An output's messages: its tag, and for a camera's, the frames' label.
  defp message_tag({tag, side}), do: {tag, Atom.to_string(side)}
  defp message_tag(tag), do: {tag, nil}

  defp route(message, routes) when tuple_size(message) >= 2 do
    tag = elem(message, 0)
    Map.get(routes, {tag, label(elem(message, 1))}) || Map.get(routes, {tag, nil})
  end

  defp route(_message, _routes), do: nil

  defp label(%{label: label}), do: label
  defp label(_payload), do: nil

  defp payload({_tag, value}), do: value
  defp payload(message), do: Tuple.delete_at(message, 0)

  # The newest value of the output waiting in the mailbox replaces `value`.
  defp newest(output, value) do
    {tag, label} = message_tag(output)

    receive do
      {:"$gen_cast", message}
      when tuple_size(message) >= 2 and elem(message, 0) == tag and
             (is_nil(label) or
                (is_map(elem(message, 1)) and :erlang.map_get(:label, elem(message, 1)) == label)) ->
        newest(output, payload(message))
    after
      0 -> value
    end
  end

  defp offer(state, output, value),
    do: state |> put_in([:slots, output, :held], value) |> release(output)

  defp ready(state, outputs) do
    outputs
    |> Enum.filter(&is_map_key(state.slots, &1))
    |> Enum.reduce(state, fn output, state ->
      state |> put_in([:slots, output, :busy], false) |> release(output)
    end)
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
    state = update_in(state, [:slots, output], &%{&1 | held: nil, handed_ms: now_ms, timer: nil})

    case exporter.handle_output(output, value, state.exporter_state) do
      {:ok, exporter_state} ->
        %{state | exporter_state: exporter_state, last_failed: false}

      {:busy, exporter_state} ->
        state = put_in(state, [:slots, output, :busy], true)
        %{state | exporter_state: exporter_state, last_failed: false}

      {:error, reason, exporter_state} ->
        message = "#{inspect(exporter)} did not export #{inspect(output)}: #{inspect(reason)}"

        %{
          state
          | exporter_state: exporter_state,
            failures: state.failures + 1,
            last_failed: true,
            last_failure: reason
        }
        |> log_once({:output, reason}, :warning, message)
    end
  end

  # Each distinct failure once, up to a bound, however often it recurs.
  defp log_once(state, failure, level, message) do
    if MapSet.member?(state.logged, failure) or MapSet.size(state.logged) >= @max_logged_failures do
      state
    else
      Logger.log(level, message)
      %{state | logged: MapSet.put(state.logged, failure)}
    end
  end

  defp failure_text(:error, reason), do: Exception.message(Exception.normalize(:error, reason))
  defp failure_text(_kind, reason), do: inspect(reason)

  defp now_ms, do: System.monotonic_time(:millisecond)
end

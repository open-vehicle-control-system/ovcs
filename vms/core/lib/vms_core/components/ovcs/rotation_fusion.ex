defmodule VmsCore.Components.OVCS.RotationFusion do
  @moduledoc """
  One shaft's rotation from several sensors that measure it, directly or
  through a fixed ratio: a motor controller's rpm and a pulse sensor on a
  gear, say.

  Every source publishes `:rotation_per_minute` of its own shaft, and nil
  while its frame is dead. Each reading is scaled by the source's `ratio`
  onto the output shaft, and every rpm in this component's options is of
  the output shaft.

  ## The rules

    * **Priority.** Sources are listed in priority order; the first one
      alive gives the value. The output is published once per sample of
      that source, never on a timer, so a consumer counting samples sees
      only fresh ones. When it dies the next one alive takes over, and
      with none alive the output is nil.
    * **Zero.** When every live source reads within its `noise_rpm`, the
      output is exactly zero: a stopped motor controller reports a stray
      erpm or two, and a standstill check wants zero.
    * **Sign.** A signed source's sign is used as is. An unsigned one gets
      the sign of the `direction_source`'s `:throttle` when one is given,
      the direction its actuator drives the motor in, otherwise the last
      sign a signed source read. A zero throttle keeps the last sign.
    * **Cross-check.** Once any live source reads at least
      `cross_check_from_rpm`, every other one is compared to the active
      source; below it a coarse sensor's resolution alone exceeds any
      useful tolerance. A gap larger than `cross_check_tolerance`, as a
      fraction of the faster reading, held for `cross_check_hold_ms`,
      raises `:cross_check_fault`. The fault is reported, not acted on.

  The priority picks a source rather than averaging: a fine source mixed
  with a coarse one would only get worse.

  ## Published

  `:rotation_per_minute` of the output shaft, `:active_source`,
  `:cross_check_gap` (the largest gap, nil while not checked) and
  `:cross_check_fault`.

  ## Options

    * `:process_name` — the name this process registers under and the
      source of its messages.
    * `:sources` — in priority order, each
      `%{source: name, ratio: number, signed: boolean, noise_rpm: number}`:
      `ratio` is output-shaft turns per source turn, `noise_rpm` defaults
      to 0.
    * `:direction_source` — optional, an actuator publishing a signed
      `:throttle`.
    * `:cross_check_from_rpm`, `:cross_check_tolerance`,
      `:cross_check_hold_ms` — see the cross-check above.
  """
  use GenServer
  require Logger
  alias Decimal, as: D
  alias OvcsBus, as: Bus
  alias OvcsBus.Units

  @zero D.new(0)

  def child_spec(%{process_name: process_name} = args) do
    %{id: process_name, start: {__MODULE__, :start_link, [args]}}
  end

  def start_link(%{process_name: process_name} = args) do
    GenServer.start_link(__MODULE__, args, name: process_name)
  end

  @impl true
  def init(%{process_name: process_name, sources: sources} = args) do
    Bus.subscribe("messages")

    {:ok,
     %{
       process_name: process_name,
       sources: Enum.map(sources, &source_spec/1),
       readings: %{},
       direction_source: Map.get(args, :direction_source),
       sign: 1,
       cross_check_from_rpm: decimal(Map.fetch!(args, :cross_check_from_rpm)),
       cross_check_tolerance: decimal(Map.fetch!(args, :cross_check_tolerance)),
       cross_check_hold_ms: Map.fetch!(args, :cross_check_hold_ms),
       gap: nil,
       mismatch_since: nil,
       fault: false
     }}
  end

  @impl true
  def handle_info(
        %Bus.Message{name: :rotation_per_minute, value: value, source: source},
        state
      ) do
    case Enum.find(state.sources, &(&1.source == source)) do
      nil ->
        {:noreply, state}

      spec ->
        state = state |> record(spec, value) |> track_sign(spec, value)

        case active_source(state) do
          # A sample of the source in use, or the last source dying.
          ^source -> {:noreply, publish(state, now())}
          nil -> {:noreply, publish(state, now())}
          _ -> {:noreply, state}
        end
    end
  end

  def handle_info(%Bus.Message{name: :throttle, value: throttle, source: source}, state)
      when not is_nil(source) and source == state.direction_source do
    {:noreply, %{state | sign: sign_of(throttle, state.sign)}}
  end

  def handle_info(%Bus.Message{}, state) do
    {:noreply, state}
  end

  defp publish(state, now) do
    {rotation, state} = compute(state, now)
    broadcast(state, :rotation_per_minute, rotation, Units.revolution_per_minute())
    broadcast(state, :active_source, source_label(active_source(state)))
    broadcast(state, :cross_check_gap, state.gap, Units.fraction())
    broadcast(state, :cross_check_fault, state.fault)
    state
  end

  @doc """
  The output rotation and the state after the cross-check, at `now` in
  milliseconds.
  """
  def compute(state, now) do
    state = cross_check(state, now)
    {rotation(state), state}
  end

  @doc false
  def rotation(state) do
    case active_spec(state) do
      nil ->
        nil

      spec ->
        cond do
          at_rest?(state) -> @zero
          spec.signed -> state.readings[spec.source]
          true -> state.readings[spec.source] |> D.abs() |> D.mult(state.sign)
        end
    end
  end

  @doc false
  def active_source(state) do
    case active_spec(state) do
      nil -> nil
      spec -> spec.source
    end
  end

  defp active_spec(state) do
    Enum.find(state.sources, &Map.has_key?(state.readings, &1.source))
  end

  defp at_rest?(state) do
    Enum.all?(state.sources, fn spec ->
      case state.readings[spec.source] do
        nil -> true
        reading -> reading |> D.abs() |> D.compare(spec.noise_rpm) != :gt
      end
    end)
  end

  @doc false
  def cross_check(state, now) do
    gap = largest_gap(state)
    mismatch = not is_nil(gap) and D.gt?(gap, state.cross_check_tolerance)
    mismatch_since = if mismatch, do: state.mismatch_since || now, else: nil
    fault = mismatch and now - mismatch_since >= state.cross_check_hold_ms

    if fault and not state.fault do
      Logger.warning(
        "#{inspect(state.process_name)}: rotation sources disagree by #{gap} " <>
          "for #{state.cross_check_hold_ms} ms: #{inspect(state.readings)}"
      )
    end

    Map.merge(state, %{gap: gap, mismatch_since: mismatch_since, fault: fault})
  end

  # The largest gap between the active source and any other live one, as
  # a fraction of the faster of the two, or nil while nothing reads fast
  # enough to be compared.
  defp largest_gap(state) do
    active = active_source(state)
    magnitudes = Map.new(state.readings, fn {source, reading} -> {source, D.abs(reading)} end)

    checked =
      not is_nil(active) and
        Enum.any?(magnitudes, fn {_, rpm} -> not D.lt?(rpm, state.cross_check_from_rpm) end)

    if checked do
      magnitudes
      |> Map.delete(active)
      |> Enum.map(fn {_, rpm} -> gap(magnitudes[active], rpm) end)
      |> Enum.max(&(D.compare(&1, &2) != :lt), fn -> nil end)
    end
  end

  defp gap(a, b) do
    faster = D.max(a, b)

    if D.eq?(faster, @zero),
      do: @zero,
      else: a |> D.sub(b) |> D.abs() |> D.div(faster) |> D.round(3)
  end

  defp record(state, spec, nil), do: %{state | readings: Map.delete(state.readings, spec.source)}

  defp record(state, spec, value) do
    reading = value |> decimal() |> D.mult(spec.ratio)
    %{state | readings: Map.put(state.readings, spec.source, reading)}
  end

  # A signed source above its noise sets the sign for the unsigned ones,
  # unless an actuator gives it.
  defp track_sign(%{direction_source: nil} = state, %{signed: true} = spec, value)
       when not is_nil(value) do
    reading = state.readings[spec.source]

    if D.gt?(D.abs(reading), spec.noise_rpm),
      do: %{state | sign: sign_of(reading, state.sign)},
      else: state
  end

  defp track_sign(state, _spec, _value), do: state

  @doc false
  def sign_of(value, last_sign) do
    cond do
      D.gt?(value, @zero) -> 1
      D.lt?(value, @zero) -> -1
      true -> last_sign
    end
  end

  defp source_spec(%{source: source, ratio: ratio, signed: signed} = spec) do
    %{
      source: source,
      ratio: decimal(ratio),
      signed: signed,
      noise_rpm: decimal(Map.get(spec, :noise_rpm, 0))
    }
  end

  defp source_label(nil), do: nil
  defp source_label(source), do: source |> inspect() |> String.split(".") |> List.last()

  defp decimal(%D{} = value), do: value
  defp decimal(value) when is_integer(value), do: D.new(value)
  defp decimal(value) when is_float(value), do: D.from_float(value)

  defp now, do: System.monotonic_time(:millisecond)

  defp broadcast(state, name, value, unit \\ nil) do
    Bus.broadcast("messages", %Bus.Message{
      name: name,
      value: value,
      unit: unit,
      source: state.process_name
    })
  end
end

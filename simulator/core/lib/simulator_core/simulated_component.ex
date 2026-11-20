defmodule SimulatorCore.SimulatedComponent do
  @moduledoc """
  One piece of a vehicle's hardware, emulated on the CAN bus for
  `SimulatorCore.Hardware`: a motor controller, a generic
  controller, a steering servo, a radio receiver.

  A simulated component reads the frames the VMS sends it, acts on the
  vehicle through efforts (`SimulatorCore.Efforts`) the world's dynamics
  model integrates, and measures the world's state
  (`SimulatorCore.WorldState`) as the hardware it stands in for would:
  each wheel's angle and spin, the body's motion. It is the inverse of
  the VMS component that drives the same hardware, is named after it,
  and reads that component's frames by the same names.

  A component not yet moved to `efforts/3` and `measure/3` acts through
  `actuations/3` and reports through `report/3`, which
  `SimulatorCore.SimulatedComponent.Legacy` runs on the same loop.
  """

  alias SimulatorCore.{Efforts, WorldState}
  alias SimulatorCore.SimulatedComponent.Legacy

  @typedoc "A frame on a network, as the bridge firmware's topology names it."
  @type frame :: {network :: atom(), frame_name :: String.t()}

  @typedoc "Signal values to merge into an emitted frame."
  @type update :: {network :: atom(), frame_name :: String.t(), signals :: map()}

  @typedoc """
  What `SimulatorCore.Hardware` hands the components in one tick: the
  world's state, the motion `Legacy` derives from it, and the vehicle's
  mass and wheel radius, through which `Legacy` turns old actuations
  into efforts.
  """
  @type tick :: %{
          world: WorldState.t(),
          motion: Legacy.motion(),
          mass_kg: float(),
          wheel_radius_m: float()
        }

  @doc """
  The simulated component's initial state, the frames it reads, and the frames it
  emits with their initial signals.
  """
  @callback init(opts :: keyword() | map()) ::
              {state :: term(), received :: [frame()], emitted :: [update()]}

  @doc "Handles one of the frames it reads, received at `now_ms`."
  @callback handle_frame(
              name :: String.t(),
              signals :: map(),
              state :: term(),
              now_ms :: integer()
            ) ::
              term()

  @doc """
  The efforts the simulated component applies this tick, from the
  world's state as it last reported it.
  """
  @callback efforts(state :: term(), WorldState.t(), now_ms :: integer()) ::
              [Efforts.actuation()]

  @doc """
  Measures the world's state as the hardware it stands in for would:
  the new state and the signals to emit.
  """
  @callback measure(state :: term(), WorldState.t(), now_ms :: integer()) ::
              {term(), [update()]}

  @doc "How a component not yet on `efforts/3` acts on the vehicle this tick."
  @callback actuations(state :: term(), Legacy.motion(), now_ms :: integer()) ::
              [Legacy.actuation()]

  @doc """
  How a component not yet on `measure/3` reports the vehicle's motion:
  counters from `wheel_turns_step`, rates from `measured_speed_m_s`.
  """
  @callback report(state :: term(), Legacy.motion(), now_ms :: integer()) ::
              {term(), [update()]}

  @optional_callbacks handle_frame: 4, efforts: 3, measure: 3, actuations: 3, report: 3

  @typedoc "A running simulated component, as `SimulatorCore.Hardware` holds it."
  @type running :: %{module: module(), state: term(), received: MapSet.t(frame())}

  @doc """
  Starts `module` with `opts`: subscribes the caller to the frames it
  reads and configures an emitter for each frame it sends.
  """
  @spec start({module(), keyword() | map()}) :: running()
  def start({module, opts}) do
    {state, received, emitted} = module.init(opts)

    received
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {network, frame_names} ->
      :ok = Cantastic.Receiver.subscribe(self(), network, frame_names)
    end)

    Enum.each(emitted, fn {network, frame_name, initial_data} ->
      :ok =
        Cantastic.Emitter.configure(network, frame_name, %{
          parameters_builder_function: :default,
          initial_data: initial_data,
          enable: true
        })
    end)

    %{module: module, state: state, received: MapSet.new(received)}
  end

  @doc "Hands `frame` to the component if it reads it."
  def handle_frame(running, %Cantastic.Frame{network_name: network, name: name} = frame, now_ms) do
    if MapSet.member?(running.received, {network, name}),
      do: %{
        running
        | state: running.module.handle_frame(name, frame.signals, running.state, now_ms)
      },
      else: running
  end

  @doc "The component's efforts this tick, none if it drives nothing."
  @spec efforts(running(), tick(), integer()) :: [Efforts.actuation()]
  def efforts(running, tick, now_ms) do
    cond do
      function_exported?(running.module, :efforts, 3) ->
        running.module.efforts(running.state, tick.world, now_ms)

      function_exported?(running.module, :actuations, 3) ->
        running.module.actuations(running.state, tick.motion, now_ms)
        |> Legacy.efforts(tick.mass_kg, tick.wheel_radius_m)

      true ->
        []
    end
  end

  @doc "Emits what the component measures, if it measures anything."
  @spec measure(running(), tick(), integer()) :: running()
  def measure(running, tick, now_ms) do
    cond do
      function_exported?(running.module, :measure, 3) ->
        emit(running, running.module.measure(running.state, tick.world, now_ms))

      function_exported?(running.module, :report, 3) ->
        emit(running, running.module.report(running.state, tick.motion, now_ms))

      true ->
        running
    end
  end

  defp emit(running, {state, updates}) do
    Enum.each(updates, fn {network, frame_name, signals} ->
      :ok = Cantastic.Emitter.update(network, frame_name, &Map.merge(&1, signals))
    end)

    %{running | state: state}
  end

  @doc "A signal's value as a float, whether Cantastic decoded it as a `Decimal` or a number."
  def float(signals, name) do
    case signals[name] do
      %Cantastic.Signal{value: %Decimal{} = value} -> Decimal.to_float(value)
      %Cantastic.Signal{value: value} -> value * 1.0
    end
  end

  @doc "`value` as a `Decimal` rounded to `places`, as Cantastic encodes a scaled signal."
  def decimal(value, places), do: (value * 1.0) |> Decimal.from_float() |> Decimal.round(places)
end

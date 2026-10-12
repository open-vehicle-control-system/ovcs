defmodule RosBridge.Simulator.SimulatedComponent do
  @moduledoc """
  One piece of a vehicle's hardware, emulated on the CAN bus for
  `RosBridge.Simulator.Hardware`: a motor controller, a brake booster, a
  steering sensor, a generic controller.

  A simulated component reads the frames the VMS sends it, acts on
  `RosBridge.Simulator.Vehicle` through actuations, and reports what
  the real hardware would from the vehicle's motion. It is the inverse
  of the VMS component that drives the same hardware, is named after
  it, and reads that component's frames by the same names.
  """

  alias RosBridge.Simulator.Vehicle

  @typedoc "A frame on a network, as the bridge firmware's topology names it."
  @type frame :: {network :: atom(), frame_name :: String.t()}

  @typedoc "Signal values to merge into an emitted frame."
  @type update :: {network :: atom(), frame_name :: String.t(), signals :: map()}

  @typedoc "See `RosBridge.Simulator.Vehicle`."
  @type actuation ::
          {:acceleration, float()}
          | {:deceleration, float()}
          | {:speed, float()}
          | {:steering, float()}

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

  @doc "How the simulated component acts on the vehicle this tick."
  @callback actuations(state :: term(), Vehicle.t(), now_ms :: integer()) :: [actuation()]

  @doc """
  Follows the vehicle's motion over the last `dt_s`, returning the new
  state and the signals to emit: counters from `wheel_turns_step`,
  rates from `measured_speed_m_s`; see `RosBridge.Simulator.Vehicle`.
  """
  @callback step(state :: term(), Vehicle.t(), dt_s :: float(), now_ms :: integer()) ::
              {term(), [update()]}

  @optional_callbacks handle_frame: 4, actuations: 3

  @typedoc "A running simulated component, as `RosBridge.Simulator.Hardware` holds it."
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

  @doc "The component's actuations this tick, none if it drives nothing."
  def actuations(running, vehicle, now_ms) do
    if function_exported?(running.module, :actuations, 3),
      do: running.module.actuations(running.state, vehicle, now_ms),
      else: []
  end

  @doc "Steps the component and emits what it reports."
  def step(running, vehicle, dt_s, now_ms) do
    {state, updates} = running.module.step(running.state, vehicle, dt_s, now_ms)

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

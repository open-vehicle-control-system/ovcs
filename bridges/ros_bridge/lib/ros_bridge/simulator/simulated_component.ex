defmodule RosBridge.Simulator.SimulatedComponent do
  @moduledoc """
  One piece of a vehicle's hardware, emulated on the CAN bus for
  `RosBridge.Simulator.Plant`: a motor controller, a brake booster, a
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

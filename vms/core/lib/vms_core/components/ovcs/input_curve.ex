defmodule VmsCore.Components.OVCS.InputCurve do
  @moduledoc """
  The curve of a hand's throttle axis, the way an EdgeTX input shapes a
  stick: a dead zone and an expo between a commander and whichever
  actuator drives the vehicle. The axis is signed, so the same curve
  shapes driving and braking.

  It follows one source's `:requested_throttle` and publishes the shaped
  request under its own process name, as it arrives, with the request it
  was given as `:input_throttle` and its parameters as `:deadzone` and
  `:expo`, so a dashboard reads everything from this one component, so the control
  level manager selects it like any other throttle source and the
  actuator never learns whether a hand or a planner is driving. Each
  hand gets its own instance with its own parameters — a radio trigger
  and a gamepad stick drift differently.

  A request in [-1, 1] goes through two steps, both symmetric around
  zero:

  1. **Dead zone** (`:deadzone`). A hand at rest is not exactly at
     centre: a trigger drifts by a few counts, a gamepad stick by a few
     percent. Requests within `deadzone` of centre read as zero, and the
     rest of the travel is stretched back over [0, 1] so nothing is lost
     at the far end. An actuator applies whatever it is given, so without
     it that drift creeps the vehicle.
  2. **Expo** (`:expo`). A blend between the raw position and its signed
     square: 0 is linear, 1 is the full square. Squaring flattens the
     start of the travel for fine control at low speed.

  Both default to leaving the request untouched. What the actuator does
  with the result — a cap, an ESC's start offset, a gear, a brake — is
  the actuator's.

  A commander that sends a physical quantity, such as
  `RosVelocityCommand`, does not go through a curve: it is wired to the
  manager directly. Neither does anything that reacts to the raw hand,
  such as `radio_breaking`, which `RadioControl.Throttle` still reports
  from the unshaped trigger.

  ## Options

    * `:process_name` — the name this process registers under and the
      source of its messages.
    * `:throttle_source` — the commander whose `:requested_throttle` it
      shapes.
    * `:deadzone`, `:expo` — fractions in [0, 1], `:deadzone` below 1.
  """
  use GenServer
  alias Decimal, as: D
  alias OvcsBus, as: Bus
  alias VmsCore.Throttle

  @zero D.new(0)
  @one D.new(1)
  @default_curve %{deadzone: @zero, expo: @zero}

  def child_spec(%{process_name: process_name} = args) do
    %{id: process_name, start: {__MODULE__, :start_link, [args]}}
  end

  def start_link(%{process_name: process_name} = args) do
    GenServer.start_link(__MODULE__, args, name: process_name)
  end

  @impl true
  def init(%{process_name: process_name, throttle_source: throttle_source} = args) do
    Bus.subscribe("messages")
    curve = curve(args)
    broadcast(process_name, :deadzone, curve.deadzone)
    broadcast(process_name, :expo, curve.expo)

    {:ok, %{process_name: process_name, throttle_source: throttle_source, curve: curve}}
  end

  @impl true
  def handle_info(
        %Bus.Message{name: :requested_throttle, value: requested_throttle, source: source},
        state
      )
      when source == state.throttle_source do
    broadcast(state.process_name, :input_throttle, requested_throttle)
    broadcast(state.process_name, :requested_throttle, shape(requested_throttle, state.curve))
    {:noreply, state}
  end

  def handle_info(%Bus.Message{}, state) do
    {:noreply, state}
  end

  defp broadcast(process_name, name, value) do
    Bus.broadcast("messages", %Bus.Message{name: name, value: value, source: process_name})
  end

  @doc """
  The curve parameters from the arguments, each defaulting to the value
  that leaves the request untouched.
  """
  def curve(args) do
    curve = Map.merge(@default_curve, Map.take(args, Map.keys(@default_curve)))

    Enum.each(curve, fn {key, value} ->
      if D.negative?(value) or D.gt?(value, @one) do
        raise ArgumentError, "#{inspect(key)} must be in [0, 1], got #{value}"
      end
    end)

    unless D.lt?(curve.deadzone, @one) do
      raise ArgumentError, ":deadzone must be below 1"
    end

    curve
  end

  @doc """
  The shaped request in [-1, 1] for a request in [-1, 1].
  """
  def shape(requested, curve) do
    requested
    |> Throttle.clamp()
    |> strip_deadzone(curve.deadzone)
    |> blend(curve.expo)
  end

  # Zero within the dead zone; beyond it the remaining travel is
  # stretched back over the full range, so full deflection still gives
  # full output.
  defp strip_deadzone(requested, deadzone) do
    magnitude = D.abs(requested)

    if D.lt?(magnitude, deadzone) or D.eq?(magnitude, deadzone) do
      @zero
    else
      magnitude
      |> D.sub(deadzone)
      |> D.div(D.sub(@one, deadzone))
      |> Throttle.signed_as(requested)
    end
  end

  # `(1 - expo) * x + expo * x * |x|`: the signed square keeps the sign
  # and the endpoints while flattening the middle of the travel, and the
  # blend sets how much of that flattening is applied.
  defp blend(requested, expo) do
    linear = requested |> D.mult(D.sub(@one, expo))
    squared = requested |> D.abs() |> D.mult(requested) |> D.mult(expo)
    D.add(linear, squared)
  end
end

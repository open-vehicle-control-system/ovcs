defmodule VmsCore.Components.Traxxas.Throttle do
  @moduledoc """
    Traxxas' ESC throttle controlled by a PWM signal

  ## From request to pulse

  A request in [-1, 1] goes through up to three steps before it becomes
  a duty cycle, and the result is capped. Everything is tunable per
  vehicle; the defaults are no dead zone, the full square, no start
  offset and no cap.

  1. **Dead zone** (`:deadzone`). A hand at rest is not exactly at
     centre: a trigger drifts by a few counts, a gamepad stick by a few
     percent. Requests within `deadzone` of centre read as zero, and the
     rest of the travel is stretched back over [0, 1] so nothing is
     lost at the far end. Without it the start offset below would turn
     that drift into a creeping vehicle.
  2. **Feel curve** (`:expo`). A blend between the raw position and its
     signed square: `expo` 0 is linear, 1 is the full square. Squaring
     flattens the middle of the travel for fine control at low speed,
     but the flatter the curve, the further along the stick the ESC's
     minimum useful pulse sits — the square alone puts it past a third
     of the travel, which reads as a dead band followed by an abrupt
     start.
  3. **Start offset** (`:start_offset`). An ESC and a motor need a
     minimum pulse before anything turns; below it the request is
     silently wasted. Every non-zero output is remapped from [0, 1]
     onto [start_offset, 1], so the first perceptible input already sits
     at the edge of motion and the rest of the travel is spent on
     speeds the vehicle can actually take. Set it to the throttle
     *output* at which the wheels first move -- the value written to
     the ESC, not the request shown on the dashboard.

  All three are properties of a *hand* on an axis, not of the actuator.
  A commander that sends a physical quantity -- `RosVelocityCommand`
  normalises metres per second -- expects its request applied as is, or
  a planner asking for a fifth of full speed gets a twenty-fifth, and a
  planner decelerating through a tiny velocity expects the vehicle to
  follow it down rather than hold the edge of motion. `:linear_sources`
  lists the sources whose request is already a physical quantity: they
  skip all three steps.

  ## The cap

  `:max_throttle` is the output a full forward request produces, and
  `:max_reverse` the same for a full negative one; both default to 1,
  `:max_reverse` to `:max_throttle` when only that is given. The cap
  *scales* rather than clips: full deflection still means "as fast as
  allowed", so a hand's output runs over `[start_offset, max]` and a
  physical quantity is multiplied by it. It applies to every source --
  a vehicle that is too fast is too fast whoever is driving.

  Two things follow. A commander that normalises a speed against the
  vehicle's full-throttle speed must use the speed reached *at the cap*,
  or it gets a fraction of what it asks for. And on a Traxxas ESC the
  first pull into negative is proportional braking, so a reverse cap
  below 1 also weakens the brake -- keep `:max_reverse` at 1 unless
  reverse speed is the problem.
  """
  use GenServer
  alias Decimal, as: D
  alias OvcsBus, as: Bus
  alias VmsCore.Components.OVCS.GenericController

  @loop_period 10
  @pwm_frequency 100
  @neutral_duty_cycle_percentage D.new("0.15")
  @duty_cycle_percentage_range D.new("0.05")
  @zero D.new(0)
  @one D.new(1)

  @default_curve %{
    deadzone: @zero,
    expo: @one,
    start_offset: @zero,
    max_throttle: @one,
    max_reverse: nil
  }

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(
        %{
          controller: controller,
          external_pwm_id: external_pwm_id,
          selected_control_level_source: selected_control_level_source
        } = args
      ) do
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)

    {:ok,
     %{
       loop_timer: timer,
       controller: controller,
       external_pwm_id: external_pwm_id,
       selected_control_level_source: selected_control_level_source,
       linear_sources: Map.get(args, :linear_sources, []),
       curve: curve(args),
       # Starts nil: nothing commands this actuator until the manager
       # names a source. The manager's default level does that on its
       # first tick.
       requested_throttle_source: nil,
       requested_throttle: @zero,
       throttle: @zero
     }}
  end

  @impl true
  def handle_info(
        %Bus.Message{
          name: :requested_throttle_source,
          value: requested_throttle_source,
          source: source
        },
        state
      )
      when source == state.selected_control_level_source do
    # Zero on the way to a level that commands nothing. Without this
    # the last request would persist — `handle_info` for
    # `:requested_throttle` gates on the source, so with no source no
    # message matches and the actuator holds. On the throttle that
    # means a vehicle that keeps driving after being switched to a
    # safe level, which is the same hazard as a stale CAN frame.
    requested = if is_nil(requested_throttle_source), do: @zero, else: state.requested_throttle

    {:noreply,
     %{
       state
       | requested_throttle_source: requested_throttle_source,
         requested_throttle: requested
     }}
  end

  def handle_info(:loop, state) do
    state =
      state
      |> apply_throttle()

    {:noreply, state}
  end

  def handle_info(
        %Bus.Message{name: :requested_throttle, value: requested_throttle, source: source},
        state
      )
      when source == state.requested_throttle_source do
    {:noreply, %{state | requested_throttle: requested_throttle}}
  end

  def handle_info(%Bus.Message{}, state) do
    {:noreply, state}
  end

  # `throttle` holds what was last written to the ESC, not what was last
  # requested. The two differ: the same request maps to a different duty
  # cycle depending on whether its source is shaped, so a switch between
  # a shaped and a linear commander at an unchanged request still has to
  # reach the PWM.
  defp apply_throttle(state) do
    throttle =
      shape(
        state.requested_throttle,
        state.requested_throttle_source in state.linear_sources,
        state.curve
      )

    case D.eq?(state.throttle, throttle) do
      true ->
        state

      false ->
        duty_cycle_percentage =
          throttle
          |> D.mult(@duty_cycle_percentage_range)
          |> D.add(@neutral_duty_cycle_percentage)

        :ok =
          GenericController.set_external_pwm(
            state.controller,
            state.external_pwm_id,
            true,
            duty_cycle_percentage,
            @pwm_frequency
          )

        %{state | throttle: throttle}
    end
  end

  @doc """
  The curve parameters from a component's arguments, each defaulting to
  the value that leaves the request untouched. Fractions of full travel,
  all in [0, 1]; `deadzone + start_offset` must stay below 1 and the
  start offset must stay below both caps.
  """
  def curve(args) do
    curve = Map.merge(@default_curve, Map.take(args, Map.keys(@default_curve)))
    curve = %{curve | max_reverse: curve.max_reverse || curve.max_throttle}

    Enum.each(curve, fn {key, value} ->
      if D.negative?(value) or D.gt?(value, @one) do
        raise ArgumentError, "#{inspect(key)} must be in [0, 1], got #{value}"
      end
    end)

    unless curve.deadzone |> D.add(curve.start_offset) |> D.lt?(@one) do
      raise ArgumentError, ":deadzone + :start_offset must be below 1"
    end

    unless D.lt?(curve.start_offset, curve.max_throttle) and
             D.lt?(curve.start_offset, curve.max_reverse) do
      raise ArgumentError, ":start_offset must be below :max_throttle and :max_reverse"
    end

    curve
  end

  @doc """
  The output in [-1, 1] for a request in [-1, 1]. A linear request is
  only scaled by the cap; a shaped one goes through all three steps and
  lands on `[start_offset, cap]`.
  """
  def shape(requested, true = _linear, curve) do
    requested |> D.abs() |> D.mult(cap(requested, curve)) |> signed_as(requested)
  end

  def shape(requested, false, curve) do
    requested
    |> strip_deadzone(curve.deadzone)
    |> blend(curve.expo)
    |> offset(curve.start_offset, cap(requested, curve))
  end

  defp cap(requested, curve) do
    if D.negative?(requested), do: curve.max_reverse, else: curve.max_throttle
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
      |> signed_as(requested)
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

  # Zero stays zero; anything else is remapped from [0, 1] onto
  # [start_offset, cap] so the smallest non-zero output already reaches
  # the ESC's edge of motion and full deflection stops at the cap.
  defp offset(requested, start_offset, cap) do
    if D.eq?(requested, @zero) do
      @zero
    else
      requested
      |> D.abs()
      |> D.mult(D.sub(cap, start_offset))
      |> D.add(start_offset)
      |> signed_as(requested)
    end
  end

  defp signed_as(magnitude, reference) do
    if D.negative?(reference), do: D.negate(magnitude), else: magnitude
  end
end

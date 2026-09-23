defmodule VmsCore.Components.Traxxas.Throttle do
  @moduledoc """
    Traxxas' ESC throttle controlled by a PWM signal

  ## From request to pulse

  A hand's request arrives already shaped: the dead zone and the feel
  curve are the hand's, applied by `OVCS.ThrottleCurve` between the
  commander and the manager. What is left here is the ESC's own:

  **Start offset** (`:start_offset`). An ESC and a motor need a minimum
  pulse before anything turns; below it the request is silently wasted.
  Every non-zero output of a hand is remapped from [0, 1] onto
  [start_offset, 1], so the first perceptible input already sits at the
  edge of motion and the rest of the travel is spent on speeds the
  vehicle can actually take. Set it to the throttle *output* at which
  the wheels first move -- the value written to the ESC, not the request
  shown on the dashboard. It lifts any non-zero request, so the hand's
  curve needs a dead zone for a hand at rest to stay at zero.

  A commander that sends a physical quantity -- `RosVelocityCommand`
  normalises metres per second -- expects its request applied as is: a
  planner decelerating through a tiny velocity expects the vehicle to
  follow it down rather than hold the edge of motion. `:linear_sources`
  lists the sources whose request is already a physical quantity: they
  skip the start offset.

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
  alias VmsCore.Throttle

  @loop_period 10
  @pwm_frequency 100
  @neutral_pulse_width_us D.new(1500)
  @pulse_width_range_us D.new(500)
  @pwm_period_us D.new(div(1_000_000, @pwm_frequency))
  @zero D.new(0)
  @one D.new(1)

  @default_curve %{
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
       # No pulse has been sent yet: even a zero first request must
       # enable the ESC signal and establish neutral.
       throttle: nil
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

    case not is_nil(state.throttle) and D.eq?(state.throttle, throttle) do
      true ->
        state

      false ->
        pulse_width_us =
          throttle
          |> D.mult(@pulse_width_range_us)
          |> D.add(@neutral_pulse_width_us)

        duty_cycle_percentage = D.div(pulse_width_us, @pwm_period_us)

        :ok =
          GenericController.set_external_pwm(
            state.controller,
            state.external_pwm_id,
            true,
            duty_cycle_percentage,
            @pwm_frequency
          )

        Bus.broadcast("messages", %Bus.Message{
          name: :throttle,
          value: throttle,
          source: __MODULE__
        })

        # This is the command before CAN/timer quantisation, not an ESC
        # readback. It makes the start threshold measurable on the car.
        Bus.broadcast("messages", %Bus.Message{
          name: :pulse_width_us,
          value: pulse_width_us,
          source: __MODULE__
        })

        %{state | throttle: throttle}
    end
  end

  @doc """
  The curve parameters from a component's arguments, each defaulting to
  the value that leaves the request untouched. Fractions of full travel,
  all in [0, 1]; the start offset must stay below both caps.
  """
  def curve(args) do
    curve = Map.merge(@default_curve, Map.take(args, Map.keys(@default_curve)))
    curve = %{curve | max_reverse: curve.max_reverse || curve.max_throttle}

    Enum.each(curve, fn {key, value} ->
      if D.negative?(value) or D.gt?(value, @one) do
        raise ArgumentError, "#{inspect(key)} must be in [0, 1], got #{value}"
      end
    end)

    unless D.lt?(curve.start_offset, curve.max_throttle) and
             D.lt?(curve.start_offset, curve.max_reverse) do
      raise ArgumentError, ":start_offset must be below :max_throttle and :max_reverse"
    end

    curve
  end

  @doc """
  The output in [-1, 1] for a request in [-1, 1]. A linear request is
  only scaled by the cap; a hand's lands on `[start_offset, cap]`.
  """
  def shape(requested, true = _linear, curve) do
    requested
    |> D.abs()
    |> D.min(@one)
    |> D.mult(cap(requested, curve))
    |> Throttle.signed_as(requested)
  end

  def shape(requested, false, curve) do
    requested
    |> Throttle.clamp()
    |> offset(curve.start_offset, cap(requested, curve))
  end

  defp cap(requested, curve) do
    if D.negative?(requested), do: curve.max_reverse, else: curve.max_throttle
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
      |> Throttle.signed_as(requested)
    end
  end
end
